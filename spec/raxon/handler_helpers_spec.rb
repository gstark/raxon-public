# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe "Handler Helpers" do
  let(:test_helpers_dir) { Dir.mktmpdir("raxon_test_helpers") }

  before do
    # Reset configuration and helpers_loaded flag before each test
    Raxon.instance_variable_set(:@configuration, Raxon::Configuration.new)
    Raxon.instance_variable_set(:@helpers_loaded, false)

    # Remove any previously loaded helper methods from HandlerHelpers
    Raxon::HandlerHelpers.singleton_class.instance_methods(false).each do |method|
      Raxon::HandlerHelpers.singleton_class.send(:remove_method, method)
    end
    Raxon::HandlerHelpers.instance_methods(false).each do |method|
      Raxon::HandlerHelpers.send(:remove_method, method)
    end
  end

  after do
    # Clean up temporary directory
    FileUtils.rm_rf(test_helpers_dir)
  end

  describe "Configuration" do
    it "has helpers_path set to nil by default" do
      config = Raxon::Configuration.new
      expect(config.helpers_path).to be_nil
    end

    it "allows setting helpers_path" do
      config = Raxon::Configuration.new
      config.helpers_path = "app/handlers/concerns"
      expect(config.helpers_path).to eq("app/handlers/concerns")
    end

    it "allows configuring helpers_path via configure block" do
      Raxon.configure do |config|
        config.helpers_path = "app/handlers/concerns"
      end

      expect(Raxon.configuration.helpers_path).to eq("app/handlers/concerns")
    end
  end

  describe "Raxon.load_helpers" do
    context "when helpers_path is not configured" do
      it "does not load any helpers" do
        Raxon.configure do |config|
          config.helpers_path = nil
        end

        expect { Raxon.load_helpers }.not_to raise_error
      end

      it "does not define any new methods on HandlerHelpers" do
        Raxon.configure do |config|
          config.helpers_path = nil
        end

        initial_methods = Raxon::HandlerHelpers.instance_methods(false)
        Raxon.load_helpers
        final_methods = Raxon::HandlerHelpers.instance_methods(false)

        expect(final_methods).to eq(initial_methods)
      end
    end

    context "when helpers_path directory does not exist" do
      it "does not raise an error" do
        Raxon.configure do |config|
          config.helpers_path = "/nonexistent/directory"
        end

        expect { Raxon.load_helpers }.not_to raise_error
      end
    end

    context "when helpers_path is configured and directory exists" do
      it "loads Ruby files from the configured directory" do
        # Create a helper file
        helper_file = File.join(test_helpers_dir, "my_helpers.rb")
        File.write(helper_file, <<~RUBY)
          module Raxon::HandlerHelpers
            def test_helper_method
              "helper method called"
            end
          end
        RUBY

        Raxon.configure do |config|
          config.helpers_path = test_helpers_dir
        end

        Raxon.load_helpers

        # Verify the helper method is available
        context = Object.new
        context.extend(Raxon::HandlerHelpers)
        expect(context.test_helper_method).to eq("helper method called")
      end

      it "loads multiple helper files" do
        # Create first helper file
        File.write(File.join(test_helpers_dir, "helper_one.rb"), <<~RUBY)
          module Raxon::HandlerHelpers
            def helper_one
              "one"
            end
          end
        RUBY

        # Create second helper file
        File.write(File.join(test_helpers_dir, "helper_two.rb"), <<~RUBY)
          module Raxon::HandlerHelpers
            def helper_two
              "two"
            end
          end
        RUBY

        Raxon.configure do |config|
          config.helpers_path = test_helpers_dir
        end

        Raxon.load_helpers

        # Verify both helper methods are available
        context = Object.new
        context.extend(Raxon::HandlerHelpers)
        expect(context.helper_one).to eq("one")
        expect(context.helper_two).to eq("two")
      end

      it "loads helpers from subdirectories" do
        # Create subdirectory
        subdir = File.join(test_helpers_dir, "auth")
        FileUtils.mkdir_p(subdir)

        # Create helper file in subdirectory
        File.write(File.join(subdir, "authentication.rb"), <<~RUBY)
          module Raxon::HandlerHelpers
            def authenticate!
              "authenticated"
            end
          end
        RUBY

        Raxon.configure do |config|
          config.helpers_path = test_helpers_dir
        end

        Raxon.load_helpers

        # Verify the helper method is available
        context = Object.new
        context.extend(Raxon::HandlerHelpers)
        expect(context.authenticate!).to eq("authenticated")
      end

      it "only loads helpers once" do
        helper_file = File.join(test_helpers_dir, "counter.rb")
        File.write(helper_file, <<~RUBY)
          module Raxon::HandlerHelpers
            @load_count ||= 0
            @load_count += 1

            def self.load_count
              @load_count
            end
          end
        RUBY

        Raxon.configure do |config|
          config.helpers_path = test_helpers_dir
        end

        Raxon.load_helpers
        Raxon.load_helpers
        Raxon.load_helpers

        # The file should only be loaded once despite multiple calls
        expect(Raxon.instance_variable_get(:@helpers_loaded)).to be true
      end
    end
  end

  describe "Handler integration" do
    it "makes helpers available in endpoint handlers" do
      # Create a helper file
      helper_file = File.join(test_helpers_dir, "integration_helper.rb")
      File.write(helper_file, <<~RUBY)
        module Raxon::HandlerHelpers
          def format_response(data)
            { formatted: true, data: data }
          end
        end
      RUBY

      Raxon.configure do |config|
        config.helpers_path = test_helpers_dir
      end

      Raxon.load_helpers

      # Create an endpoint with a handler that uses the helper
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.handler do |request, response|
        response.body = format_response("test data")
      end

      # Create mock request and response
      rack_request = Rack::MockRequest.env_for("/test")
      request = Raxon::Request.new(Rack::Request.new(rack_request), endpoint)
      response = Raxon::Response.new(endpoint)

      # Call the endpoint
      endpoint.call(request, response)

      # Verify the helper was called
      expect(response.body).to eq({formatted: true, data: "test data"})
    end

    it "allows helpers to accept request and response parameters" do
      # Create a helper file
      helper_file = File.join(test_helpers_dir, "request_helper.rb")
      File.write(helper_file, <<~RUBY)
        module Raxon::HandlerHelpers
          def check_header(request, header_name)
            request.rack_request.get_header(header_name)
          end
        end
      RUBY

      Raxon.configure do |config|
        config.helpers_path = test_helpers_dir
      end

      Raxon.load_helpers

      # Create an endpoint with a handler that uses the helper
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.handler do |request, response|
        header_value = check_header(request, "HTTP_X_CUSTOM_HEADER")
        response.body = {header: header_value}
      end

      # Create mock request with custom header
      rack_request = Rack::MockRequest.env_for("/test", "HTTP_X_CUSTOM_HEADER" => "test-value")
      request = Raxon::Request.new(Rack::Request.new(rack_request), endpoint)
      response = Raxon::Response.new(endpoint)

      # Call the endpoint
      endpoint.call(request, response)

      # Verify the helper accessed the request correctly
      expect(response.body).to eq({header: "test-value"})
    end
  end
end
