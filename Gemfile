# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

# 兄弟 checkout を path で束ねる。gear は三つとも「実装を選ぶ」のではなく
# 「語彙・文法・境界」として使うので、リリース版でなく作業版に追随する。
gem 'darkcore', path: '../darkcore-ruby'
gem 'zeolite',  path: '../zeolite'

group :development, :test do
  gem 'minitest', '~> 5.0'
  gem 'rake', '~> 13.0'
  gem 'rubocop', require: false
end
