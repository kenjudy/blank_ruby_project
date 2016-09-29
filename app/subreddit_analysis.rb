require 'rubygems'
require 'bundler/setup'
require 'redd'
require 'yaml'
require 'json'
require 'sqlite3'

class SubredditAnalysis
  attr_accessor :props, :client, :access
  attr_reader :db

  COMMENTER_TYPE = 'commenters'
  SUBREDDIT_TYPE = 'subreddits'
  SUBMISSION_TYPE = 'submissions'
  SUBMITTER_TYPE = 'submitters'

  def initialize(config_file, props = {})
    @environment = ENV['environment'] || 'production'
    log("Running in #{@environment} mode.")
    @props = YAML.load_file(config_file).merge(props)
    @db = init_db
  end

  def close
    @db.close if @db
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

  def submissions(subreddit, number = @props['submission_depth'])
    return users_from_submissions_and_comments(number, subreddit)
  end

  def commenters(subreddit, submission, number = @props['comment_depth'])
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
      id = submission.id
    end
    data = read(display_name, type, { 'name' => display_name, 'ended_at' => 0, type => [], "id" => id })
    count =   data['ended_at']
    limit = number - count  > 100 ? 100 : number - count
    if (limit > 0) then
      (count..number-1).each_slice(limit) do |a|
        log("retrieve #{limit} #{type} for #{display_name} #{submission.nil? ? '' : "new submission: " + submission.id} starting at #{a.first}")
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

  def save(name, type, data)
    log "Save #{type} with ended_at #{data['ended_at']} and after #{data['after']}"
    case type
    when SUBREDDIT_TYPE
      @db.execute "insert or ignore into subreddits (name, metadata) values ('#{data['display_name']}',  '#{JSON.pretty_generate(data).gsub("'", "''")}');"
    when SUBMITTER_TYPE
      @db.execute "insert or ignore into subreddits (name) values ('#{data['name']}');"
      @db.execute "update subreddits set ended_at=#{data['ended_at']}, after='#{data['after'] || ''}' where name='#{data['name']}';"
      for submitter in data['submitters']
        @db.execute "insert or replace into submitters (subreddit_name, name) values ('#{data['name']}', '#{submitter}');"
      end
    when COMMENTER_TYPE
      @db.execute "insert or replace into submissions (subreddit_name, id, ended_at, after) values ('#{data['name']}', '#{data['id']}', #{data['ended_at']}, '#{data['after'] || ''}');"
      for commenter in data['commenters']
        @db.execute "insert or replace into commenters (subreddit_name, submission_id, name) values ('#{data['name']}', '#{data['id']}', '#{submitter}');"
      end
    else
      log("Unhandled save: #{name}, #{type}, #{default}")
    end
  end

  def read(name, type, default)
    data = default
    begin
      subreddit = @db.execute("select name, ended_at, after from subreddits where name = '#{name}';").first
      case type
        when SUBMITTER_TYPE
          submitters = @db.execute("select name from submitters where subreddit_name = '#{name}';")
          log("retrieved submitters for #{name}: subreddit ended_at #{subreddit[1]}")
          data = { 'name' => subreddit[0], 'ended_at' => subreddit[1] || default['ended_at'], 'after' => subreddit[2] || default['after'], 'submitters' => submitters}
        when COMMENTER_TYPE
          subreddit = @db.execute("select name from subreddits where name = '#{name}';").first
          submission = @db.execute("select id, ended_at, after from submissions where id='#{default['id']}'").first
          if (submission.nil?)
            return default
          else
            commenter_list = @db.execute("select name from commenters where submission_id='#{default['id']}'")
            data = { 'name' => subreddit[0], 'id' => submission[0], 'ended_at' => submission[1] || default['ended_at'], 'after' => submission[2] || default['after'], 'commenters' => commenter_list.flatten }
          end
        else
          log("Unhandled read: #{name}, #{type}, #{default}")
        end
        return data
      rescue Exception => e
        log e
        return default
      end
  end

  def self.run(subreddit)
    begin
      bot = SubredditAnalysis.new('./config/config.yml')
      bot.authorize
      subreddit = bot.subreddit(subreddit)
      bot.submissions(subreddit)
    ensure
      bot.close if bot
    end
  end

  private

  def log(message)
    unless(ENV['environment'] == 'test') then
      puts message
      puts message.backtrace if message.respond_to?(:backtrace)
    end
  end

  def get_commenters(subreddit, data, limit, count)
    comment_list = subreddit.get_comments(limit: limit, count: count, after: data['after'])
    return to_author_list(comment_list, COMMENTER_TYPE, data, limit, count)
  end

  def get_submitters(subreddit, data, limit, count)
    submission_list = subreddit.get_new(limit: limit, count: count, after: data['after'])
    submission_list.each { |s| commenters(subreddit, s) }
    return to_author_list(submission_list, SUBMITTER_TYPE, data, limit, count)
  end

  def to_author_list(list, type, data, limit, count)
    authors = list.map { |s| s.author }
    data[type] = (data[type] + authors).uniq
    data['ended_at'] = limit + count
    data['after'] = list.last.id
    return data
  end

  def init_db
    db = SQLite3::Database.new "#{@props['data_folder']}/subreddit_analysis_#{@environment}.db"
    db.execute <<-SQL
      create table if not exists subreddits (
        name varchar(255) PRIMARY KEY,
        metadata text,
        ended_at integer,
        after varchar(255)
      );
    SQL
    db.execute <<-SQL
      create table if not exists submitters (
        subreddit_name varchar(255) references subreddit(name) ON UPDATE CASCADE,
        name varchar(255),
        PRIMARY KEY (name, subreddit_name)
      );
    SQL
    db.execute <<-SQL
      create table if not exists submissions (
        subreddit_name varchar(255) references subreddit(name) ON UPDATE CASCADE,
        id varchar(255) PRIMARY KEY,
        ended_at integer,
        after varchar(255)
      );
    SQL
    db.execute <<-SQL
      create table if not exists commenters (
        subreddit_name varchar(255) references subreddit(name) ON UPDATE CASCADE,
        submission_id varchar(255) references submission(id) ON UPDATE CASCADE,
        name varchar(255),
        PRIMARY KEY (submission_id, name)
      );
    SQL
    return db
  end
end
