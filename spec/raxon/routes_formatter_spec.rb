require "spec_helper"
require "raxon/routes_formatter"

RSpec.describe Raxon::RoutesFormatter do
  before do
    Raxon::RouteLoader.reset!
  end

  describe ".display" do
    it "creates a new instance and calls display" do
      formatter_instance = instance_double(described_class)
      expect(described_class).to receive(:new).and_return(formatter_instance)
      expect(formatter_instance).to receive(:display)

      described_class.display
    end
  end

  describe "#display" do
    context "when no routes are registered" do
      it "displays 'No routes found' message" do
        formatter = described_class.new

        expect { formatter.display }.to output(/No routes found/).to_stdout
      end

      it "does not display a table" do
        formatter = described_class.new

        output = capture_stdout { formatter.display }

        expect(output).not_to include("Method")
        expect(output).not_to include("Path")
      end
    end

    context "when routes are registered" do
      before do
        Raxon::RouteLoader.register("routes/api/v1/users/get.rb") do |endpoint|
          endpoint.description "Get all users"
          endpoint.handler do |_request, response|
            response.code = :ok
            response.body = []
          end
        end

        Raxon::RouteLoader.register("routes/api/v1/users/post.rb") do |endpoint|
          endpoint.description "Create a new user"
          endpoint.before do |_request, _response|
            # Authentication check
          end
          endpoint.handler do |_request, response|
            response.code = :created
            response.body = {}
          end
        end

        Raxon::RouteLoader.register("routes/api/v1/users/$id/get.rb") do |endpoint|
          endpoint.handler do |_request, response|
            response.code = :ok
            response.body = {}
          end
        end

        # Stub reset! and load! to prevent clearing our test routes
        allow(Raxon::RouteLoader).to receive(:reset!)
        allow(Raxon::RouteLoader).to receive(:load!)
      end

      it "displays a table with route information" do
        formatter = described_class.new

        output = capture_stdout { formatter.display }

        expect(output).to include("Method")
        expect(output).to include("Path")
        expect(output).to include("Before")
        expect(output).to include("Handler")
        expect(output).to include("Description")
      end

      it "displays route methods" do
        formatter = described_class.new

        output = capture_stdout { formatter.display }

        expect(output).to include("GET")
        expect(output).to include("POST")
      end

      it "displays route paths" do
        formatter = described_class.new

        output = capture_stdout { formatter.display }

        expect(output).to include("/api/v1/users")
        expect(output).to include("/api/v1/users/{id}")
      end

      it "displays before indicator when route has before block" do
        formatter = described_class.new

        output = capture_stdout { formatter.display }

        expect(output).to include("✓")
      end

      it "displays dash when route has no before block" do
        formatter = described_class.new

        output = capture_stdout { formatter.display }

        expect(output).to include("-")
      end

      it "displays handler indicator when route has handler" do
        formatter = described_class.new

        output = capture_stdout { formatter.display }

        # All our test routes have handlers
        expect(output.scan(/✓/).count).to be >= 3
      end

      it "displays route descriptions" do
        formatter = described_class.new

        output = capture_stdout { formatter.display }

        expect(output).to include("Get all users")
        expect(output).to include("Create a new user")
      end

      it "displays '(no description)' for routes without description" do
        formatter = described_class.new

        output = capture_stdout { formatter.display }

        expect(output).to include("(no description)")
      end

      it "displays total routes count" do
        formatter = described_class.new

        output = capture_stdout { formatter.display }

        expect(output).to include("Total routes: 3")
      end

      it "sorts routes by depth, path, and method" do
        Raxon::RouteLoader.reset!

        # Register routes in non-alphabetical order
        Raxon::RouteLoader.register("routes/api/v1/posts/get.rb") do |endpoint|
          endpoint.handler { |_request, response| response.code = :ok }
        end

        Raxon::RouteLoader.register("routes/api/v1/users/get.rb") do |endpoint|
          endpoint.handler { |_request, response| response.code = :ok }
        end

        Raxon::RouteLoader.register("routes/api/v1/comments/get.rb") do |endpoint|
          endpoint.handler { |_request, response| response.code = :ok }
        end

        # Stub reset! and load! to prevent clearing our test routes
        allow(Raxon::RouteLoader).to receive(:reset!)
        allow(Raxon::RouteLoader).to receive(:load!)

        formatter = described_class.new
        output = capture_stdout { formatter.display }

        # Check that paths appear in sorted order
        comments_index = output.index("/api/v1/comments")
        posts_index = output.index("/api/v1/posts")
        users_index = output.index("/api/v1/users")

        expect(comments_index).to be < posts_index
        expect(posts_index).to be < users_index
      end

      it "sorts routes by depth (path segment count)" do
        Raxon::RouteLoader.reset!

        Raxon::RouteLoader.register("routes/api/v1/users/$id/posts/$post_id/get.rb") do |endpoint|
          endpoint.handler { |_request, response| response.code = :ok }
        end

        Raxon::RouteLoader.register("routes/api/v1/users/get.rb") do |endpoint|
          endpoint.handler { |_request, response| response.code = :ok }
        end

        Raxon::RouteLoader.register("routes/api/v1/users/$id/get.rb") do |endpoint|
          endpoint.handler { |_request, response| response.code = :ok }
        end

        # Stub reset! and load! to prevent clearing our test routes
        allow(Raxon::RouteLoader).to receive(:reset!)
        allow(Raxon::RouteLoader).to receive(:load!)

        formatter = described_class.new
        output = capture_stdout { formatter.display }

        # Shorter paths should appear before longer paths
        # Split output into lines and find the lines containing each path
        lines = output.split("\n")
        users_line_idx = lines.index { |line| line.include?("/api/v1/users") && !line.include?("{id}") }
        user_id_line_idx = lines.index { |line| line.include?("/api/v1/users/{id}") && !line.include?("posts") }
        posts_line_idx = lines.index { |line| line.include?("/api/v1/users/{id}/posts/{post_id}") }

        expect(users_line_idx).to be < user_id_line_idx
        expect(user_id_line_idx).to be < posts_line_idx
      end
    end
  end

  # Helper method to capture stdout
  def capture_stdout
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original_stdout
  end
end
