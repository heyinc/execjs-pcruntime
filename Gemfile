# frozen_string_literal: true

source 'https://rubygems.org'

git_source(:github) { |repo_name| "https://github.com/#{repo_name}" }

# Specify your gem's dependencies in execjs-pcruntime.gemspec
gemspec

gem 'execjs', '~> 2.0'

group :development do
  gem 'rubocop', require: false
  gem 'rubocop-minitest', require: false
  gem 'rubocop-performance', require: false
  gem 'rubocop-rake', require: false
end

group :test do
  gem 'minitest', '~> 5.0'
  gem 'rake', '~> 10.0'
end
