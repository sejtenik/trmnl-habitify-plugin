require 'net/http'
require 'json'
require 'dotenv/load'
require 'active_support/time'
require 'uri'

DAYS_COUNT = 7

###### methods #############

def short_round(number)
  if number == 0
    return 0;
  end

  number > 1 ? number.round : number.round(1)
end

#universal method for calling various habitify rest endpoints with simple caching
def call_habitify(path, params, use_cache)
  uri = URI.join("https://api.habitify.me", path)
  uri.query = URI.encode_www_form(params)

  if use_cache
    cache_file = cache_file_path(uri)

    if File.exist?(cache_file)
      puts "Using cached response for #{uri} in #{cache_file}"
      return JSON.parse(File.read(cache_file))
    end
  end

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  headers = {
    'Content-Type' => 'application/json',
    'Authorization' => "#{ENV['HABITIFY_API_KEY']}"
  }

  puts "Getting data from #{uri}"

  request = Net::HTTP::Get.new(uri, headers)
  response = http.request(request)

  if response.is_a?(Net::HTTPSuccess)
    if use_cache  #TODO cache invalidation!
      puts "Saving cached response for #{uri} in #{cache_file}"
      File.write(cache_file, response.body)
    end
    json_data = JSON.parse(response.body)
    puts "Response: #{json_data}"
    json_data
  else
    puts "Error: #{response.code} - #{response.message}"
  end
end

# Helper function to generate a unique cache filename based on the request
def cache_file_path(url)
  cache_dir = "cache"
  Dir.mkdir(cache_dir) unless Dir.exist?(cache_dir)

  # Generate a unique filename based on the URL and params hash
  file_name = Digest::SHA256.hexdigest(url)
  File.join(cache_dir, "#{file_name}.json")
end

#for the given habit_id finds statuses in range @start_date..@end_date
# and counts current streak (event before @start_date)
def get_habit_history_and_streak(habit_id, habit_start_date)
  result = {:streak => 0, :skipped => 0}
  on_streak = true
  current_date = @end_date
  is_for_today = true
  statuses = {}
  while on_streak or current_date >= @start_date

    unless current_date == @end_date
      is_for_today = false
      current_date = current_date.at_end_of_day
    end

    if current_date >= habit_start_date
      habit_status_response = call_habitify("/status/#{habit_id}", { target_date: current_date.iso8601}, !is_for_today)
      status = habit_status_response["data"]["status"]
    else
      status = 'none'
    end

    #don't store more statuses than needed
    if current_date >= @start_date
      statuses[current_date.strftime("%Y-%m-%d")] = status
    end

    #streak counting algorithm
    if status == 'failed' or status == 'none'
      on_streak = false
    elsif status == 'skipped'
      result[:skipped] += 1 if on_streak
    elsif is_for_today and status == 'in_progress'
      #nop - don't break a streak, but also don't count ;)
      result[:streak] += 0
    elsif on_streak
      result[:streak] += 1
    end

    current_date = current_date.yesterday
  end

  if result[:streak] > 0
    result[:skipped_percentage] = short_round(result[:skipped] / result[:streak].to_f * 100)
  else
    result[:skipped_percentage] = 0
  end
  #order statuses from oldest to newest
  result[:statuses] = statuses.values.reverse

  result
end

#returns all user habits with its streak days count and history for DAYS_COUNT days
def get_habits_data
  habits_response = call_habitify("/habits", {}, false)

  @start_date = Time.now - (DAYS_COUNT-1) * 24 * 60 * 60
  @end_date = Time.now

  habits = []

  habits_response["data"].each do |habit_response|
    next if habit_response["is_archived"]
    habit = {:name => habit_response["name"]}
    puts habit
    habit_start_date = Time.parse(habit_response["start_date"]).beginning_of_day
    habit_id = habit_response["id"]
    habit_history = get_habit_history_and_streak(habit_id, habit_start_date)
    habit.merge! habit_history
    habits.append habit
  end

  habits.sort_by! {|habit| habit[:streak] }

  #pupulate table header
  header = []

  (@start_date.to_date..@end_date.to_date).each do |date|
    date_formated =  date.strftime("%Y-%m-%d")
    header.append date_formated
  end

  {:header => header,
   :habits => habits}
rescue StandardError => e
  puts "Error: #{e.message}"
  raise
end

def send_to_trmnl(data_payload)
  trmnl_webhook_url = "https://usetrmnl.com/api/custom_plugins/#{ENV['TRMNL_PLUGIN_ID']}"

  puts('Send data to trmnl webhook')
  uri = URI(trmnl_webhook_url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  headers = {
    'Content-Type' => 'application/json',
    'Authorization' => "Bearer #{ENV['TRMNL_API_KEY']}"
  }

  request = Net::HTTP::Post.new(uri.path, headers)
  request.body = {merge_variables: data_payload}.to_json

  response = http.request(request)

  if response.is_a?(Net::HTTPSuccess)
    current_timestamp = DateTime.now.iso8601
    puts "Tasks sent successfully to TRMNL at #{current_timestamp}"
  else
    puts "Error: #{response.body}"
  end
rescue StandardError => e
  puts "Error: #{e.message}"
  raise
end

############# execution #########

data = get_habits_data
puts '-------------'
puts data
send_to_trmnl(data)
