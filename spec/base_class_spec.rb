require 'minitest/autorun'
require 'rubygems'
require 'bundler/setup'
require 'pry'
require 'mocha/mini_test'
require "net/http"

require File.join(__dir__, '..', 'app', 'base_class.rb')

describe BaseClass do
  
  def clean_up
  end
  
  before do
    ENV['ENV'] = 'test'
    @base_class = BaseClass.new
    clean_up
    #Net::HTTP.stubs(:start).yields(nil)
    #@base_class.stubs(:foo).returns(true)
  end
  
  after do
    clean_up
  end

  describe "run" do
     it "runs" do
       assert_equal(true, BaseClass.run)
    end
  end

  
end