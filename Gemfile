source "https://rubygems.org"

gemspec name: "raxon"

gem "ostruct"
gem "thor", "~> 1.0"

group :development, :test do
  # Raxon has no runtime dependency on ActiveRecord; the suite exercises the
  # ActiveRecord schema-introspection adapter and instrumentation against it.
  gem "activerecord", ">= 7.0", "< 9"
  gem "flog"
  gem "puma", "~> 7.0"
  gem "rake", "~> 13.0"
  gem "rackup", "~> 2.0"
  gem "rspec", "~> 3.0"
  gem "simplecov", "~> 0.22"
  gem "standardrb", "~> 1.0"
end

gem "debug", "~> 1.11"
