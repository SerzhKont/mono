# frozen_string_literal: true

require 'csv'
require 'date'
require 'fileutils'
require 'json'
require 'logger'
require 'time'
require 'faraday'
require 'kdl'

module MonobankExporter
  API_URL = 'https://api.monobank.ua'
  MAX_PERIOD = 2_682_000 # 31 день + 1 час — лимит API
  RATE_LIMIT_SLEEP = 60  # 1 запрос на 60 секунд
  EXPORT_DIR = 'export'
  LOG_DIR = 'logs'
  LOG_FILE = File.join(LOG_DIR, 'export.log')

  CURRENCIES = {
    980 => 'UAH', 840 => 'USD', 978 => 'EUR',
    826 => 'GBP', 985 => 'PLN'
  }.freeze

  CSV_HEADERS = [
    'Дата і час', 'Опис', 'MCC', 'Сума', 'Сума у валюті операції', 'Валюта',
    'Комісія', 'Кешбек', 'Баланс', 'Коментар', 'Контрагент', 'ЄДРПОУ',
    'IBAN контрагента', 'Receipt ID', 'Invoice ID', 'Hold', 'ID операції'
  ].freeze

  module_function

  def run
    FileUtils.mkdir_p(EXPORT_DIR)
    config = KDL.load_file('config.kdl')
    period = parse_period(config)
    clients = parse_clients(config)

    if clients.empty?
      log(:error, 'В config.kdl нет ни одного клиента с непустым именем и токеном')
      return 1
    end

    log(:info, "Старт выгрузки. Период: #{format_time(period[:from])} — #{format_time(period[:to])}. Клиентов: #{clients.size}")

    results = clients.map do |client|
      begin
        export_client(client, period)
      rescue StandardError => e
        log(:error, "Клиент #{client[:name]}: исключение #{e.class}: #{e.message}")
        log(:error, e.backtrace.first(5).join("\n")) if e.backtrace
        false
      end
    end

    failed = results.count(false)
    log(failed.zero? ? :info : :error,
        "Готово. Успешно: #{results.count(true)}, с ошибками: #{failed}")
    failed.zero? ? 0 : 1
  rescue StandardError => e
    log(:error, "Критическая ошибка: #{e.class}: #{e.message}")
    log(:error, e.backtrace.first(5).join("\n")) if e.backtrace
    1
  end

  def log(level, message)
    loggers.each { |logger| logger.public_send(level, message) }
  end

  def loggers
    @loggers ||= begin
      FileUtils.mkdir_p(LOG_DIR)
      formatter = proc do |severity, time, _progname, msg|
        "[#{time.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{msg}\n"
      end
      [Logger.new($stdout), Logger.new(LOG_FILE)].each do |logger|
        logger.formatter = formatter
        logger.level = Logger::INFO
      end
    end
  end

  def parse_clients(config)
    node = config['clients']
    return [] unless node

    node.children.filter_map do |child|
      name = child.arguments.first&.value.to_s
      token = child.properties['token']&.value.to_s
      if name.empty? || token.empty?
        log(:warn, "Пропущен клиент с пустым именем или токеном: name=#{name.inspect}")
        next
      end
      { name: name, token: token }
    end
  end

  def parse_period(config)
    from_time = parse_date(setting_value(config, 'from'), end_of_day: false)
    to_time = parse_date(setting_value(config, 'to'), end_of_day: true)

    from, to =
      if from_time && to_time
        [from_time, to_time]
      elsif from_time
        [from_time, end_of_day(from_time)]
      elsif to_time
        [start_of_day(to_time), to_time]
      else
        default_period
      end

    if from > to
      log(:warn, 'Период некорректен (from > to), используется предыдущий день')
      from, to = default_period
    end

    { from: from.to_i, to: to.to_i }
  end

  def setting_value(config, key)
    config['settings']&.children&.find { |node| node.name == key }&.arguments&.first&.value
  end

  def parse_date(value, end_of_day:)
    return nil if value.nil? || value.to_s.strip.empty?

    date = Date.strptime(value.to_s.strip, '%Y-%m-%d')
    end_of_day ? self.end_of_day(date) : start_of_day(date)
  rescue ArgumentError
    log(:error, "Некорректная дата в config.kdl: #{value.inspect} (ожидается YYYY-MM-DD)")
    nil
  end

  def start_of_day(time)
    Time.local(time.year, time.month, time.day, 0, 0, 0)
  end

  def end_of_day(time)
    Time.local(time.year, time.month, time.day, 23, 59, 59)
  end

  def default_period
    yesterday = Date.today.prev_day
    from = Time.local(yesterday.year, yesterday.month, yesterday.day, 0, 0, 0)
    [from, end_of_day(from)]
  end

  def export_client(client, period)
    conn = connection(client[:token])
    response = conn.get('/personal/client-info')
    unless response.success?
      log(:error, "Клиент #{client[:name]}: client-info вернул #{response.status}: #{truncate(response.body)}")
      return false
    end

    info = JSON.parse(response.body)
    accounts = Array(info['accounts']).select { |account| account['type'] == 'fop' }
    log(:info, "Клиент #{client[:name]}: #{info['name']}, найдено fop-счетов: #{accounts.size}")

    if accounts.empty?
      log(:warn, "Клиент #{client[:name]}: счета type == 'fop' не найдены")
      return false
    end

    dir = File.join(EXPORT_DIR, sanitize(client[:name]))
    FileUtils.mkdir_p(dir)
    stamp = Time.now.strftime('%Y-%m-%d_%H-%M-%S')
    throttle = { last: nil }

    accounts.map do |account|
      export_account(conn, client, account, period, dir, stamp, accounts.size, throttle)
    end.all?
  end

  def export_account(conn, client, account, period, dir, stamp, total, throttle)
    label = "Клиент #{client[:name]}, счёт #{account_tag(account)}"
    items = []

    windows(period[:from], period[:to]).each do |from, to|
      response = throttled_get(conn, "/personal/statement/#{account['id']}/#{from}/#{to}", throttle)
      unless response.success?
        log(:error, "#{label}: statement вернул #{response.status}: #{truncate(response.body)}")
        return false
      end
      items.concat(JSON.parse(response.body))
    end

    path = File.join(dir, filename(client[:name], account, stamp, total))
    write_csv(path, items)
    log(:info, "#{label}: операций #{items.size}, сохранено в #{path}")
    true
  end

  def windows(from, to)
    result = []
    cursor = from
    while cursor <= to
      chunk_end = [cursor + MAX_PERIOD, to].min
      result << [cursor, chunk_end]
      cursor = chunk_end + 1
    end
    result
  end

  def throttled_get(conn, path, throttle)
    if throttle[:last]
      wait = RATE_LIMIT_SLEEP - (Time.now - throttle[:last])
      sleep(wait) if wait.positive?
    end
    response = conn.get(path)
    throttle[:last] = Time.now
    response
  end

  def connection(token)
    Faraday.new(
      url: API_URL,
      headers: { 'Content-Type' => 'application/json', 'X-Token' => token },
      request: { timeout: 30, open_timeout: 30 }
    )
  end

  def write_csv(path, items)
    content = CSV.generate(col_sep: ';') do |csv|
      csv << CSV_HEADERS
      items.sort_by { |item| item['time'].to_i }.each { |item| csv << csv_row(item) }
    end

    File.open(path, 'w:UTF-8') do |file|
      file.write("\uFEFF")
      file.write(content)
    end
  end

  def csv_row(item)
    [
      format_time(item['time'].to_i),
      item['description'],
      item['mcc'],
      money(item['amount']),
      money(item['operationAmount']),
      currency(item['currencyCode']),
      rate(item['commissionRate']),
      money(item['cashbackAmount']),
      money(item['balance']),
      item['comment'],
      item['counterName'],
      item['counterEdrpou'],
      item['counterIban'],
      item['receiptId'],
      item['invoiceId'],
      item['hold'] ? 'так' : 'ні',
      item['id']
    ]
  end

  def filename(name, account, stamp, total)
    suffix = total > 1 ? "_#{account_tag(account)}" : ''
    "#{sanitize(name)}#{suffix}_#{stamp}.csv"
  end

  def account_tag(account)
    pan = account['maskedPan']&.first.to_s
    return pan[-4..] unless pan.empty?

    iban = account['iban'].to_s
    return iban[-4..] unless iban.empty?

    account['id'].to_s[0, 6]
  end

  def sanitize(name)
    cleaned = name.to_s.gsub(%r{[/\\\u0000-\u001f]}, '_').strip
    cleaned.empty? ? 'client' : cleaned
  end

  def money(value)
    return nil if value.nil?

    format('%.2f', value.to_i / 100.0)
  end

  def rate(value)
    return nil if value.nil?

    format('%.2f', value)
  end

  def currency(code)
    CURRENCIES.fetch(code.to_i, code.to_s)
  end

  def format_time(unix)
    Time.at(unix).strftime('%Y-%m-%d %H:%M:%S')
  end

  def truncate(body)
    body.to_s.gsub(/\s+/, ' ')[0, 500]
  end
end

exit(MonobankExporter.run) if $PROGRAM_NAME == __FILE__
