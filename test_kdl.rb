# frozen_string_literal: true

require 'kdl'

config = KDL.load_file('config.kdl')

def parse_clients(config)
  node = config['clients']
  return [] unless node

  node.children.filter_map do |child|
    name = child.arguments.first&.value.to_s
    token = child.properties['token']&.value.to_s
    if name.empty? || token.empty?
      puts 'No data found'
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
    puts 'Период некорректен'
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

period = parse_period(config)
clients = parse_clients(config)

puts period
puts clients
