# frozen_string_literal: true

require "spec_helper"

RSpec.describe Raxon::Routes do
  let(:routes) { described_class.new }
  let(:endpoint) { Raxon::OpenApi::Endpoint.new }

  describe "#initialize" do
    it "initializes with an empty routes hash" do
      expect(routes.empty?).to be(true)
      expect(routes.size).to eq(0)
    end
  end

  describe "#register" do
    it "registers a route with method and path" do
      routes.register("GET", "/users", endpoint)

      expect(routes.size).to eq(1)
      expect(routes.empty?).to be(false)
    end

    it "normalizes method to uppercase" do
      routes.register("get", "/users", endpoint)

      result = routes.find("GET", "/users")
      expect(result).not_to be_nil
      expect(result[:endpoint]).to eq(endpoint)
    end

    it "stores mustermann pattern for the route" do
      routes.register("GET", "/users/{id}", endpoint)

      result = routes.find("GET", "/users/123")
      expect(result).not_to be_nil
      expect(result[:params]).to eq({id: "123"})
    end

    it "allows multiple routes with different methods" do
      endpoint1 = Raxon::OpenApi::Endpoint.new
      endpoint2 = Raxon::OpenApi::Endpoint.new

      routes.register("GET", "/users", endpoint1)
      routes.register("POST", "/users", endpoint2)

      expect(routes.size).to eq(2)
      expect(routes.find("GET", "/users")[:endpoint]).to eq(endpoint1)
      expect(routes.find("POST", "/users")[:endpoint]).to eq(endpoint2)
    end

    it "allows multiple routes with different paths" do
      endpoint1 = Raxon::OpenApi::Endpoint.new
      endpoint2 = Raxon::OpenApi::Endpoint.new

      routes.register("GET", "/users", endpoint1)
      routes.register("GET", "/posts", endpoint2)

      expect(routes.size).to eq(2)
      expect(routes.find("GET", "/users")[:endpoint]).to eq(endpoint1)
      expect(routes.find("GET", "/posts")[:endpoint]).to eq(endpoint2)
    end
  end

  describe "#find" do
    context "with exact match" do
      it "finds route by exact method and path" do
        routes.register("GET", "/users", endpoint)

        result = routes.find("GET", "/users")

        expect(result).not_to be_nil
        expect(result[:endpoint]).to eq(endpoint)
        expect(result[:endpoints]).to include(endpoint)
      end

      it "returns nil for non-existent route" do
        routes.register("GET", "/users", endpoint)

        result = routes.find("GET", "/posts")

        expect(result).to be_nil
      end

      it "returns nil for wrong method" do
        routes.register("GET", "/users", endpoint)

        result = routes.find("POST", "/users")

        expect(result).to be_nil
      end

      it "is case-insensitive for HTTP method" do
        routes.register("GET", "/users", endpoint)

        result = routes.find("get", "/users")

        expect(result).not_to be_nil
        expect(result[:endpoint]).to eq(endpoint)
      end
    end

    context "with pattern matching" do
      it "matches routes with path parameters" do
        routes.register("GET", "/users/{id}", endpoint)

        result = routes.find("GET", "/users/123")

        expect(result).not_to be_nil
        expect(result[:endpoint]).to eq(endpoint)
        expect(result[:params]).to eq({id: "123"})
      end

      it "extracts multiple path parameters" do
        routes.register("GET", "/users/{user_id}/posts/{post_id}", endpoint)

        result = routes.find("GET", "/users/42/posts/99")

        expect(result).not_to be_nil
        expect(result[:params]).to eq({user_id: "42", post_id: "99"})
      end

      it "returns nil for non-matching pattern" do
        routes.register("GET", "/users/{id}", endpoint)

        result = routes.find("GET", "/posts/123")

        expect(result).to be_nil
      end

      it "prefers exact match over pattern match" do
        exact_endpoint = Raxon::OpenApi::Endpoint.new
        pattern_endpoint = Raxon::OpenApi::Endpoint.new

        routes.register("GET", "/users/all", exact_endpoint)
        routes.register("GET", "/users/{id}", pattern_endpoint)

        result = routes.find("GET", "/users/all")

        expect(result[:endpoint]).to eq(exact_endpoint)
      end
    end

    context "with route hierarchy" do
      it "includes parent routes in hierarchy" do
        parent_endpoint = Raxon::OpenApi::Endpoint.new
        child_endpoint = Raxon::OpenApi::Endpoint.new

        routes.register("GET", "/api", parent_endpoint)
        routes.register("GET", "/api/users", child_endpoint)

        result = routes.find("GET", "/api/users")

        expect(result[:endpoint]).to eq(child_endpoint)
        expect(result[:endpoints]).to eq([parent_endpoint, child_endpoint])
      end

      it "builds hierarchy with multiple levels" do
        level1 = Raxon::OpenApi::Endpoint.new
        level2 = Raxon::OpenApi::Endpoint.new
        level3 = Raxon::OpenApi::Endpoint.new

        routes.register("GET", "/api", level1)
        routes.register("GET", "/api/v1", level2)
        routes.register("GET", "/api/v1/users", level3)

        result = routes.find("GET", "/api/v1/users")

        expect(result[:endpoint]).to eq(level3)
        expect(result[:endpoints]).to eq([level1, level2, level3])
      end

      it "only includes matching parent paths" do
        users_endpoint = Raxon::OpenApi::Endpoint.new
        posts_endpoint = Raxon::OpenApi::Endpoint.new

        routes.register("GET", "/api/users", users_endpoint)
        routes.register("GET", "/api/posts", posts_endpoint)

        result = routes.find("GET", "/api/users")

        expect(result[:endpoints]).to eq([users_endpoint])
        expect(result[:endpoints]).not_to include(posts_endpoint)
      end

      it "returns single endpoint when no parents exist" do
        routes.register("GET", "/users", endpoint)

        result = routes.find("GET", "/users")

        expect(result[:endpoints]).to eq([endpoint])
      end

      it "preserves params when building hierarchy" do
        parent_endpoint = Raxon::OpenApi::Endpoint.new
        child_endpoint = Raxon::OpenApi::Endpoint.new

        routes.register("GET", "/users", parent_endpoint)
        routes.register("GET", "/users/{id}", child_endpoint)

        result = routes.find("GET", "/users/123")

        expect(result[:params]).to eq({id: "123"})
        expect(result[:endpoint]).to eq(child_endpoint)
        expect(result[:endpoints]).to include(parent_endpoint)
        expect(result[:endpoints].size).to be >= 1
      end
    end
  end

  describe "#all" do
    it "returns all registered routes" do
      endpoint1 = Raxon::OpenApi::Endpoint.new
      endpoint2 = Raxon::OpenApi::Endpoint.new

      routes.register("GET", "/users", endpoint1)
      routes.register("POST", "/users", endpoint2)

      all_routes = routes.all

      expect(all_routes).to be_a(Hash)
      expect(all_routes.size).to eq(2)
    end

    it "returns empty hash when no routes registered" do
      expect(routes.all).to eq({})
    end
  end

  describe "#reset" do
    it "clears all registered routes" do
      routes.register("GET", "/users", endpoint)
      routes.register("POST", "/posts", endpoint)

      expect(routes.size).to eq(2)

      routes.reset

      expect(routes.size).to eq(0)
      expect(routes.empty?).to be(true)
    end

    it "allows registering new routes after reset" do
      routes.register("GET", "/users", endpoint)
      routes.reset

      new_endpoint = Raxon::OpenApi::Endpoint.new
      routes.register("POST", "/posts", new_endpoint)

      expect(routes.size).to eq(1)
      expect(routes.find("POST", "/posts")[:endpoint]).to eq(new_endpoint)
    end
  end

  describe "#size" do
    it "returns 0 for empty routes" do
      expect(routes.size).to eq(0)
    end

    it "returns count of registered routes" do
      routes.register("GET", "/users", endpoint)
      routes.register("POST", "/users", endpoint)
      routes.register("GET", "/posts", endpoint)

      expect(routes.size).to eq(3)
    end
  end

  describe "#empty?" do
    it "returns true when no routes registered" do
      expect(routes.empty?).to be(true)
    end

    it "returns false when routes exist" do
      routes.register("GET", "/users", endpoint)

      expect(routes.empty?).to be(false)
    end

    it "returns true after reset" do
      routes.register("GET", "/users", endpoint)
      routes.reset

      expect(routes.empty?).to be(true)
    end
  end

  describe "#each" do
    it "iterates over all routes" do
      endpoint1 = Raxon::OpenApi::Endpoint.new
      endpoint2 = Raxon::OpenApi::Endpoint.new

      routes.register("GET", "/users", endpoint1)
      routes.register("POST", "/users", endpoint2)

      count = 0
      routes.each do |key, data|
        count += 1
        expect(key).to be_a(Hash)
        expect(data).to be_a(Hash)
        expect(data).to have_key(:endpoint)
        expect(data).to have_key(:mustermann)
      end

      expect(count).to eq(2)
    end

    it "returns Enumerator when no block given" do
      routes.register("GET", "/users", endpoint)

      enumerator = routes.each

      expect(enumerator).to be_a(Enumerator)
      expect(enumerator.count).to eq(1)
    end
  end

  describe "Enumerable methods" do
    before do
      3.times do |i|
        routes.register("GET", "/route#{i}", Raxon::OpenApi::Endpoint.new)
      end
    end

    it "supports map" do
      keys = routes.map { |key, _| key }

      expect(keys).to be_a(Array)
      expect(keys.size).to eq(3)
    end

    it "supports select" do
      get_routes = routes.select { |key, _| key[:method] == "GET" }

      expect(get_routes.size).to eq(3)
    end

    it "supports any?" do
      has_routes = routes.any?

      expect(has_routes).to be(true)
    end
  end

  describe "complex routing scenarios" do
    it "handles mixed exact and pattern routes" do
      exact = Raxon::OpenApi::Endpoint.new
      pattern1 = Raxon::OpenApi::Endpoint.new
      pattern2 = Raxon::OpenApi::Endpoint.new

      routes.register("GET", "/users/me", exact)
      routes.register("GET", "/users/{id}", pattern1)
      routes.register("GET", "/users/{id}/posts/{post_id}", pattern2)

      # Exact match
      result1 = routes.find("GET", "/users/me")
      expect(result1[:endpoint]).to eq(exact)
      expect(result1[:params]).to be_nil

      # Pattern match
      result2 = routes.find("GET", "/users/123")
      expect(result2[:endpoint]).to eq(pattern1)
      expect(result2[:params]).to eq({id: "123"})

      # Nested pattern match
      result3 = routes.find("GET", "/users/123/posts/456")
      expect(result3[:endpoint]).to eq(pattern2)
      expect(result3[:params]).to eq({id: "123", post_id: "456"})
    end

    it "handles root path" do
      routes.register("GET", "/", endpoint)

      result = routes.find("GET", "/")

      expect(result).not_to be_nil
      expect(result[:endpoint]).to eq(endpoint)
    end

    it "handles deeply nested paths" do
      routes.register("GET", "/api/v1/users/{user_id}/posts/{post_id}/comments/{comment_id}", endpoint)

      result = routes.find("GET", "/api/v1/users/1/posts/2/comments/3")

      expect(result).not_to be_nil
      expect(result[:params]).to eq({user_id: "1", post_id: "2", comment_id: "3"})
    end

    it "handles routes with similar prefixes" do
      user_endpoint = Raxon::OpenApi::Endpoint.new
      users_endpoint = Raxon::OpenApi::Endpoint.new

      routes.register("GET", "/user", user_endpoint)
      routes.register("GET", "/users", users_endpoint)

      result1 = routes.find("GET", "/user")
      result2 = routes.find("GET", "/users")

      expect(result1[:endpoint]).to eq(user_endpoint)
      expect(result2[:endpoint]).to eq(users_endpoint)
    end
  end
end
