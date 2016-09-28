require 'rubygems'
require 'bundler/setup'
require 'redd'
require 'yaml'
require 'json'

class SubredditAnalysis
  attr_accessor :props, :client, :access

  COMMENTER_TYPE = 'commenters'
  SUBREDDIT_TYPE = 'subreddit'
  SUBMISSION_TYPE = 'submission'
  SUBMITTER_TYPE = 'submitters'

  def initialize(config_file, props = {})
    @props = YAML.load_file(config_file).merge(props)
  end

  def authorize
    log("authorizing")
    @client = Redd.it(:script, props['client_id'], props['client_secret'], props['username'], props['password'], user_agent: props['user_agent'])
    @access = @client.authorize!
  end

  def subreddit(name)
    log("get subreddit #{name}")
    subreddit = @client.subreddit_from_name(name)
    save(name, SUBREDDIT_TYPE, JSON.parse(subreddit.to_json))
    return subreddit
  end

  def submissions(subreddit, number = @props['comment_depth'])
    # display_name = subreddit.display_name
    # data = read(display_name, SUBMITTER_TYPE, { 'name' => display_name, 'ended_at' => 0, 'submitters' => [] })
    # count = data['ended_at']
    # limit = number - count  > 100 ? 100 : number - count
    # if (limit > 0) then
    #   (count..number-1).each_slice(limit) do |a|
    #     log("retrieve #{limit} submissions starting at #{a.first}")
    #     data = get_submitters(subreddit, data, limit, a.first)
    #     log("saving #{data['submitters'].length}...")
    #     save(display_name, SUBMITTER_TYPE, data)
    #   end
    # end
    # return data
    return users_from_submissions_and_comments(number, subreddit)
  end

  #:count (Integer) — default: 0 — The number of items already seen in the listing.
  #:limit (1..100) — default: 25 — The maximum number of things to return.
  def commenters(subreddit, submission, number = @props['comment_depth'])
    # display_name = "#{subreddit.display_name}_#{submission.id }"
    # data = read(display_name, COMMENTER_TYPE, { 'name' => display_name, 'ended_at' => 0, 'commenters' => [] })
    # count = data['ended_at']
    # limit = number - count  > 100 ? 100 : number - count
    # if (limit > 0) then
    #   (count..number-1).each_slice(limit) do |a|
    #     log("retrieve #{limit} commenters starting at #{a.first}")
    #     data = get_commenters(subreddit, data, limit, a.first)
    #     log("saving #{data['commenters'].length}...")
    #     save(display_name, COMMENTER_TYPE, data)
    #   end
    # end
    # return data
    return users_from_submissions_and_comments(number, subreddit, submission)
  end

  #:count (Integer) — default: 0 — The number of items already seen in the listing.
  #:limit (1..100) — default: 25 — The maximum number of things to return.
  def users_from_submissions_and_comments(number, subreddit, submission = nil)
    display_name = subreddit.display_name
    if (submission.nil?) then
      type = SUBMITTER_TYPE
    else
      type = COMMENTER_TYPE
      display_name += "_#{submission.id }"
    end
    data = read(display_name, type, { 'name' => display_name, 'ended_at' => 0, type => [] })
    count = data['ended_at']
    limit = number - count  > 100 ? 100 : number - count
    if (limit > 0) then
      (count..number-1).each_slice(limit) do |a|
        log("retrieve #{limit} #{type} starting at #{a.first}")
        if (submission.nil?)
          data = get_submitters(subreddit, data, limit, a.first)
        else
          data = get_commenters(subreddit, data, limit, a.first)
        end
        log("saving #{data[type].length}...")
        save(display_name, type, data)
      end
    end
    return data
  end

  def save(name, type, obj)
    File.open("#{@props['data_folder']}/#{name}_#{type}.json","w") do |f|
      f.write(JSON.pretty_generate(obj))
    end
  end

  def read(name, type, default)
    begin
      return JSON.load File.new("#{@props['data_folder']}/#{name}_#{type}.json")
    rescue Exception => e
      log e
      return default
    end
  end

  def self.run(subreddit)
    bot = SubredditAnalysis.new('./config/config.yml')
    bot.authorize
    subreddit = bot.subreddit(subreddit)
    bot.submissions(subreddit)
  end

  private

  def log(message)
    unless(ENV['environment'] == 'test') then
      puts message
    end
  end

  def get_commenters(subreddit, data, limit, count)
    #puts "next #{limit} starting at #{count}"
    comment_list = subreddit.get_comments(limit: limit, count: count, after: data['after'])
    new_commenters = comment_list.map { |c| c.author }
    data[COMMENTER_TYPE] = (data[COMMENTER_TYPE] + new_commenters).uniq
    data['ended_at'] = limit + count
    data['after'] = comment_list.last.id
    return data
  end

  def get_submitters(subreddit, data, limit, count)
    #puts "next #{limit} starting at #{count}"
    submission_list = subreddit.get_new(limit: limit, count: count, after: data['after'])
    submission_list.each { |s| commenters(subreddit, s) }
    new_submitters = submission_list.map { |s| s.author }
    data[SUBMITTER_TYPE] = (data[SUBMITTER_TYPE] + new_submitters).uniq
    data['ended_at'] = limit + count
    data['after'] = submission_list.last.id
    return data
  end

end
