require 'minitest/autorun'
require 'rubygems'
require 'bundler/setup'
require 'pry'
require 'mocha/mini_test'
require "net/http"

require File.join(__dir__, '..', 'app', 'subreddit_analysis.rb')

ENV['environment'] = 'test'

describe SubredditAnalysis do

  describe "instance methods" do
    before do
      @subreddit_analysis = SubredditAnalysis.new('spec/fixtures/config.yml')
      @mock = MiniTest::Mock.new
      @subreddit_analysis.client = @mock
      Redd.stubs(:it).returns(@mock)
    end

    it "initializes properties" do
      assert_equal('reddit_bot', @subreddit_analysis.props["username"])
    end

    it "authorizes" do
      @mock.expect(:authorize!, nil)
      @subreddit_analysis.authorize
      assert(@mock.verify)
    end

    describe "retrieve subreddit" do
      before do
        @subreddit_analysis.stubs(save: nil)
      end

      it "retrieves a subreddit by name" do
        @mock.expect(:subreddit_from_name, {}, ['foo'])
        @subreddit_analysis.subreddit('foo')
        assert(@mock.verify)
      end
    end

    describe "read data" do
      it 'retrieves from the data store' do
        assert_equal(JSON.load(File.new("spec/fixtures/funny_1324234_commenters.json")), @subreddit_analysis.read('funny_1324234', 'commenters', { name: 'foo' }))
      end


      it 'returns default if there is no data store file' do
        assert_equal({ name: 'foo'}, @subreddit_analysis.read('foo', 'commenter', { name: 'foo' }))
      end
    end

    describe "comment authors" do
      before do
        @commenters = [ stub(author: "Je---ja", id: '23456')]
        @submission = stub(id: '1324234')
        @subreddit = MiniTest::Mock.new
        @subreddit_analysis.stubs(save: nil)
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
        @submissions = [ stub(author: "Je---ja", id: '23456')]
        @subreddit = MiniTest::Mock.new
        @subreddit_analysis.stubs(save: nil, commenters: nil)
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

    end
  end

  # describe "run" do
  #   before do
  #     # @subreddit_analysis = SubredditAnalysis.run
  #   end
  #   it "authorizes" do
  #     # assert_instance_of(Redd::Objects::Subreddit, SubredditAnalysis.run('funny'))
  #   end
  # end


end
