# frozen_string_literal: true

require 'faraday'
require 'json'
require 'dotenv/load'

TOKEN = ENV.fetch('ALEKSANDRENKO_TOKEN')
time_to = Time.now.to_i
time_from = time_to - (24 * 60 * 60)

def connection
  Faraday.new(
    url: 'https://api.monobank.ua',
    headers: { 'Content-Type' => 'application/json', 'X-Token' => TOKEN }
  )
end

response = connection.get('/personal/client-info')

if response.success?
  client_info = JSON.parse(response.body)
  puts JSON.pretty_generate(client_info)
else
  puts "Ошибка: #{response.status}"
  puts response.body
end

account_id = client_info['accounts'].find { |acc| acc['type'] == 'fop' }&.dig('id')

response = connection.get("/personal/statement/#{account_id}/#{time_from}/#{time_to}")

if response.success?
  bank_statement = JSON.parse(response.body)
  puts JSON.pretty_generate(bank_statement)
else
  puts "Ошибка: #{response.status}"
  puts response.body
end
