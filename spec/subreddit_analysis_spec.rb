require 'minitest/autorun'
require 'rubygems'
require 'bundler/setup'
require 'pry'
require 'mocha/mini_test'
require "net/http"
require 'sqlite3'


require File.join(__dir__, '..', 'app', 'subreddit_analysis.rb')

ENV['environment'] = 'test'

describe SubredditAnalysis do
  before do
    @subreddit_analysis = SubredditAnalysis.new('spec/fixtures/config.yml')
    subreddit = JSON.load(File.new("spec/fixtures/funny_subreddit.json"))
    submission = JSON.load(File.new("spec/fixtures/funny_submitters.json"))
    @commenters = JSON.load(File.new("spec/fixtures/funny_1324234_commenters.json"))
    @subreddit_analysis.db.execute "delete from subreddits"
    @subreddit_analysis.db.execute "insert into subreddits (name, metadata, ended_at, after) values ('funny', '#{JSON.pretty_generate(subreddit).gsub("'", "''")}', #{submission['ended_at']}, '#{submission['after']}')"
    @subreddit_analysis.db.execute "delete from submissions"
    @subreddit_analysis.db.execute "insert into submissions (subreddit_name, id, ended_at, after)  values ('funny', '1324234', #{@commenters['ended_at']}, '#{@commenters['after']}')"
    @subreddit_analysis.db.execute "delete from submitters"
    for submitter in submission["submitters"]
      @subreddit_analysis.db.execute "insert into submitters (subreddit_name, name)  values ('funny', '#{submitter}')"
    end
    @subreddit_analysis.db.execute "delete from commenters"
    for commenter in @commenters["commenters"]
      @subreddit_analysis.db.execute "insert into commenters (subreddit_name, submission_id, name)  values ('funny', '1324234', '#{commenter}')"
    end
    @users = (@commenters['commenters'] + submission['submitters']).uniq.sort
    @subreddit_analysis.db.execute "delete from users"
    (0..@users.length/2).each do |i|
      @subreddit_analysis.db.execute "insert or ignore into users (name) values ('#{@users[i]}')"
    end

    @client = MiniTest::Mock.new
    @subreddit_analysis.client = @client
    Redd.stubs(:it).returns(@client)
  end

  after do
    @subreddit_analysis.close
  end

  it "initializes properties" do
    assert_equal('reddit_bot', @subreddit_analysis.props["username"])
  end

  it "authorizes" do
    @client.expect(:authorize!, nil)
    @subreddit_analysis.authorize
    assert(@client.verify)
  end

  describe "retrieve subreddit" do
    before do
      # @subreddit_analysis.stubs(save: nil)
    end

    it "retrieves a subreddit by name" do
      @client.expect(:subreddit_from_name, {}, ['foo'])
      @subreddit_analysis.subreddit('foo')
      assert(@client.verify)
    end
  end

  describe "read data" do
    describe "retrieves from data store" do
      before do
        @result = @subreddit_analysis.read('funny', 'commenters', { 'id' => '1324234'})
      end
      it 'matches name' do
        assert_equal(@commenters['name'], @result['name']);
      end
      it 'matches ended_at' do
        assert_equal(@commenters['ended_at'], @result['ended_at']);
      end
      it 'matches name' do
        assert_equal(@commenters['after'], @result['after']);
      end
      it 'matches name' do
        assert_equal(@commenters['id'], @result['id']);
      end
      it 'matches name' do
        assert_equal(@commenters['commenters'].sort, @result['commenters'].sort);
      end
    end

    it 'returns default if there is no data store file' do
      assert_equal({ name: 'foo'}, @subreddit_analysis.read('foo', 'commenter', { name: 'foo'}))
    end
  end

  describe "comment authors" do
    before do
      @commenters = [ stub(author: "Je---ja", id: '23456')]
      @submission = stub(id: '1324234')
      @subreddit = MiniTest::Mock.new
      # @subreddit_analysis.stubs(save: nil)
    end

    it "requests 100 commenters if requested" do
      @subreddit.expect(:display_name, 'foo')
      @subreddit.expect(:display_name, 'foo')
      @subreddit.expect(:get_comments, @commenters, [{limit: 100, count: 0, after: nil}])
      @subreddit_analysis.commenters(@subreddit, @submission, 100)
      assert(@subreddit.verify)
    end

    describe "with saved data" do
      before do
        @subreddit.expect(:display_name, 'funny')
        @subreddit.expect(:display_name, 'funny')
      end

      it "uses saved data" do
        assert_equal(100, @subreddit_analysis.commenters(@subreddit, @submission, 100)['ended_at'])
      end

      it "asks for incremental content" do
        @subreddit.expect(:get_comments, @commenters , [{limit: 100, count: 100, after: "12345"}])
        assert_equal(200, @subreddit_analysis.commenters(@subreddit, @submission, 200)['ended_at'])
      end

      it "de-dupes" do
        @subreddit.expect(:get_comments, @commenters , [{limit: 100, count: 100, after: "12345"}])
        assert_equal(86, @subreddit_analysis.commenters(@subreddit, @submission, 200)['commenters'].length)
      end

      it "saves last count" do
        @subreddit.expect(:get_comments, @commenters , [{limit: 50, count: 100, after: "12345"}])
        assert_equal(150, @subreddit_analysis.commenters(@subreddit, @submission, 150)['ended_at'])
      end

      it "slices if requested count is greater than 100" do
        @subreddit.expect(:get_comments, @commenters , [{limit: 100, count: 100, after: "12345"}])
        @subreddit.expect(:get_comments, @commenters , [{limit: 100, count: 200, after: "23456"}])
        assert_equal(300, @subreddit_analysis.commenters(@subreddit, @submission, 300)['ended_at'])
      end

    end
  end

  describe "subreddit submissions" do
    before do
      @submissions = [ stub(author: "Je---ja", id: '23456', get_new: [])]
      @subreddit = MiniTest::Mock.new
      @subreddit_analysis.stubs(commenters: nil) #save: nil,
    end

    it "requests 100 submissions if requested" do
      @subreddit.expect(:display_name, 'foo')
      @subreddit.expect(:display_name, 'foo')
      @subreddit.expect(:get_new, @submissions, [{limit: 100, count: 0, after: nil}])
      @subreddit_analysis.submissions(@subreddit, 100)
      assert(@subreddit.verify)
    end

    describe "with saved data" do
      before do
        @subreddit.expect(:display_name, 'funny')
        @subreddit.expect(:display_name, 'funny')
      end

      it "uses saved data" do
        assert_equal(100, @subreddit_analysis.submissions(@subreddit, 100)['ended_at'])
      end

      it "asks for incremental content" do
        @subreddit.expect(:get_new, @submissions , [{limit: 100, count: 100, after: "54wmuj"}])
        assert_equal(200, @subreddit_analysis.submissions(@subreddit, 200)['ended_at'])
      end

      it "de-dupes" do
        @subreddit.expect(:get_new, @submissions , [{limit: 100, count: 100, after: "54wmuj"}])
        assert_equal(6, @subreddit_analysis.submissions(@subreddit, 200)['submitters'].length)
      end

      it "saves last count" do
        @subreddit.expect(:get_new, @submissions , [{limit: 50, count: 100, after: "54wmuj"}])
        assert_equal(150, @subreddit_analysis.submissions(@subreddit, 150)['ended_at'])
      end

      it "slices if requested count is greater than 100" do
        @subreddit.expect(:get_new, @submissions , [{limit: 100, count: 100, after: "54wmuj"}])
        @subreddit.expect(:get_new, @submissions , [{limit: 100, count: 200, after: "23456"}])
        assert_equal(300, @subreddit_analysis.submissions(@subreddit, 300)['ended_at'])
      end

    end

    describe 'users' do
      before do
        @subreddit = stub(display_name: 'funny')
        @users = @subreddit_analysis.commenters_and_submitters(@subreddit)
        #@subreddit_analysis.stubs(commenters: nil) #save: nil,
      end

      it "returns commenters and submitters for a subreddit" do
        assert_equal(@users, @subreddit_analysis.commenters_and_submitters(@subreddit))
      end

      it "gets user from name" do
        for name in @users
          @client.expect(:user_from_name, stub(fullname: name, to_json: '{"fullname": "#{name}"}', get_submitted: [ stub(subreddit: 'the_boo', fullname: '12343')]), [name])
        end
        @subreddit_analysis.users_other_submissions(@subreddit)
        assert(@client.verify)
      end

    end

  end
end
