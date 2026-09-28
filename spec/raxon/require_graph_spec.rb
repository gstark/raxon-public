# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "require \"raxon\"" do
  it "does not load Thor or OpenStruct into a server process" do
    lib = File.expand_path("../../lib", __dir__)
    script = 'require "raxon"; print [defined?(Thor), defined?(OpenStruct)].inspect'
    output, status = Open3.capture2e(RbConfig.ruby, "-I", lib, "-e", script)

    expect(status).to be_success, output
    expect(output).to eq("[nil, nil]")
  end
end
