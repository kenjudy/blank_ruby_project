require 'rubygems'
require 'bundler/setup'
require 'redd'
require 'yaml'
require 'json'
require 'sqlite3'
require 'csv'

class SubredditAnalysis
  attr_accessor :props, :client, :access
  attr_reader :db

  COMMENTER_TYPE = 'commenters'
  SUBREDDIT_TYPE = 'subreddits'
  SUBMISSION_TYPE = 'submissions'
  SUBMITTER_TYPE = 'submitters'
  USER_TYPE = 'users'
  USER_SUBMISSION_TYPE = 'user_submissions'
  USER_COMMENT_TYPE = 'user_comments'

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

  def user(name)
    log("get user #{name}")
    reddit_user =  @client.user_from_name(name)
    save(name, USER_TYPE, JSON.parse(reddit_user.to_json))
    user = read(name, USER_TYPE, { 'name' => reddit_user.name, 'submissions_ended_at' => 0, 'comments_ended_at' => 0, 'submissions' => [], 'comments' => []})
    user['reddit_obj'] = reddit_user
    return user
  end

  def submissions(subreddit, depth = @props['submission_depth'])
    return users_from_submissions_and_comments(depth, subreddit)
  end

  def commenters(subreddit, submission, depth = @props['comment_depth'])
    return users_from_submissions_and_comments(depth, subreddit, submission)
  end

  def users_other_submissions(subreddit)
    users = commenters_and_submitters(subreddit)
    depth = @props['submission_depth']
    for name in users do
      begin
        log("find submissions for #{name}")
        u = user(name)
        count = u['submissions_ended_at']
        #:count (Integer) — default: 0 — The number of items already seen in the listing.
        #:limit (1..100) — default: 25 — The maximum number of things to return.
        limit = depth - count  > 100 ? 100 : depth - count
        if (limit > 0) then
          (count..depth-1).each_slice(limit) do |a|
            log("retrieve #{limit} submissions for #{name} starting at #{a.first}")
            u = get_submissions(u, limit, a.first)
          end
          save(name, USER_SUBMISSION_TYPE, u)
        end
      rescue Exception => e
        log(e)
      end
    end
  end

  def users_other_comments(subreddit)
    users = commenters_and_submitters(subreddit)
    depth = @props['comment_depth']
    for name in users do
      begin
        log("find comments for #{name}")
        u = user(name)
        count = u['comments_ended_at']
        #:count (Integer) — default: 0 — The number of items already seen in the listing.
        #:limit (1..100) — default: 25 — The maximum number of things to return.
        limit = depth - count  > 100 ? 100 : depth - count
        if (limit > 0) then
          (count..depth-1).each_slice(limit) do |a|
            log("retrieve #{limit} comments for #{name} starting at #{a.first}")
            u = get_comments(u, limit, a.first)
          end
          save(name, USER_COMMENT_TYPE, u)
        end
      rescue Exception => e
        log(e)
      end
    end
  end

  def users_from_submissions_and_comments(depth, subreddit, submission = nil)
    display_name = subreddit.display_name
    if (submission.nil?) then
      type = SUBMITTER_TYPE
    else
      type = COMMENTER_TYPE
      id = submission.id
    end
    data = read(display_name, type, { 'name' => display_name, 'ended_at' => 0, type => [], "id" => id })
    #:count (Integer) — default: 0 — The number of items already seen in the listing.
    #:limit (1..100) — default: 25 — The maximum number of things to return.
    count =   data['ended_at']
    limit = depth - count  > 100 ? 100 : depth - count
    if (limit > 0) then
      (count..depth-1).each_slice(limit) do |a|
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
    log "Save #{type} #{name} with ended_at #{data['ended_at']} and after #{data['after']}"
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
        @db.execute "insert or replace into commenters (subreddit_name, submission_id, name) values ('#{data['name']}', '#{data['id']}', '#{commenter}');"
      end
    when USER_TYPE
      @db.execute "insert or ignore into users (name, metadata, comments_ended_at, submissions_ended_at) values ('#{data['name']}',  '#{JSON.pretty_generate(data).gsub("'", "''")}', 0, 0);"
    when USER_SUBMISSION_TYPE
      @db.execute "insert or ignore into users (name) values ('#{data['reddit_obj'].name}');"
      @db.execute "update users set submissions_ended_at=#{data['submissions_ended_at']}, submissions_after='#{data['submissions_after'] || ''}' where name='#{data['reddit_obj'].name}';"
      for subreddit_name in data['submissions']
        @db.execute "insert or replace into user_submissions (user_name, subreddit_name) values ('#{data['reddit_obj'].name}', '#{subreddit_name}');"
      end
    when USER_COMMENT_TYPE
      @db.execute "insert or ignore into users (name) values ('#{data['reddit_obj'].name}');"
      @db.execute "update users set comments_ended_at=#{data['comments_ended_at']}, comments_after='#{data['comments_after'] || ''}' where name='#{data['reddit_obj'].name}';"
      for subreddit_name in data['comments']
        @db.execute "insert or replace into user_comments (user_name, subreddit_name) values ('#{data['reddit_obj'].name}', '#{subreddit_name}');"
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
        when USER_TYPE
          user = @db.execute("select * from users where name = '#{name}';")
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

  def analyze(subreddit)
    result = @db.execute <<-SQL
    select count(*), subreddit_name from
      (select subreddit_name
        from user_submissions
        where user_name in
          (select distinct(name) from commenters where subreddit_name='#{subreddit.display_name}'
          union
          select distinct(name) from submitters where subreddit_name='#{subreddit.display_name}' order by name asc)
      union select subreddit_name
        from user_comments
          where user_name in
          (select distinct(name) from commenters where subreddit_name='#{subreddit.display_name}'
            union select distinct(name) from submitters where subreddit_name='#{subreddit.display_name}' order by name asc))
      group by subreddit_name order by subreddit_name;
      SQL
      filename = "reports/#{subreddit.display_name}_#{DateTime.now.strftime('%Y_%m_%d')}.csv"
      log("writing results to #{filename}")
      CSV.open(filename, "wb") do |csv|
        csv << ["count", "subreddit"]
        for row in result
          csv << row
        end
      end
  end

  def commenters_and_submitters(subreddit)
    commenters =  @db.execute "select name from commenters where subreddit_name='#{subreddit.display_name}'"
    submitters = @db.execute "select name from submitters where subreddit_name='#{subreddit.display_name}'"
    return (commenters.flatten + submitters.flatten).sort.uniq
  end

  def self.run(subreddit)
    begin
      bot = SubredditAnalysis.new('./config/config.yml')
      bot.authorize
      subreddit = bot.subreddit(subreddit)
      bot.submissions(subreddit)
      bot.users_other_submissions(subreddit)
      bot.users_other_comments(subreddit)
      bot.analyze(subreddit)
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


  def get_submissions(u, limit, count)
    args = { limit: limit, count: count }
    if(u['submissions_after']) then
      args[:after] = u['submissions_after']
    end
    list = u['reddit_obj'].get_submitted(args)
    u['submissions'] = (list.map {|r| r.subreddit } + u['submissions']).uniq ##field that references subreddit???
    u['ended_at'] = limit + count
    u['after'] = list.last.fullname
    return u
  end

  def get_comments(u, limit, count)
    args = { limit: limit, count: count }
    if(u['comments_after']) then
      args[:after] = u['comments_after']
    end
    list = u['reddit_obj'].get_submitted(args)
    u['comments'] = (list.map {|r| r.subreddit } + u['comments']).uniq ##field that references subreddit???
    u['ended_at'] = limit + count
    u['after'] = list.last.fullname
    return u
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
        subreddit_name varchar(255) references subreddits(name) ON UPDATE CASCADE,
        name varchar(255),
        PRIMARY KEY (name, subreddit_name)
      );
    SQL
    db.execute <<-SQL
      create table if not exists submissions (
        subreddit_name varchar(255) references subreddits(name) ON UPDATE CASCADE,
        id varchar(255) PRIMARY KEY,
        ended_at integer,
        after varchar(255)
      );
    SQL
    db.execute <<-SQL
      create table if not exists commenters (
        subreddit_name varchar(255) references subreddits(name) ON UPDATE CASCADE,
        submission_id varchar(255) references submissions(id) ON UPDATE CASCADE,
        name varchar(255),
        PRIMARY KEY (submission_id, name)
      );
    SQL
    db.execute <<-SQL
      create table if not exists users (
        name varchar(255) PRIMARY KEY,
        metadata text,
        submissions_ended_at integer,
        submissions_after varchar(255),
        comments_ended_at integer,
        comments_after varchar(255)
      );
    SQL
    db.execute <<-SQL
      create table if not exists user_submissions (
        user_name varchar(255)  references users(name) ON UPDATE CASCADE,
        subreddit_name varchar(255)
      );
    SQL
    db.execute <<-SQL
      create table if not exists user_comments (
        user_name varchar(255)  references users(name) ON UPDATE CASCADE,
        subreddit_name varchar(255)
      );
    SQL
    return db
  end
end
