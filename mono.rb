# frozen_string_literal: true

require 'faraday'
require 'json'

TOKEN = ENV.fetch('ALEKSANDRENKO_TOKEN')

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
