require "spec_helper"

RSpec.describe Raxon::Template do
  it "HTML-escapes interpolated locals by default" do
    template = described_class.new("<h1><%= title %></h1>")

    result = template.render(title: "<script>alert(1)</script>")

    expect(result).to eq("<h1>&lt;script&gt;alert(1)&lt;/script&gt;</h1>")
  end

  it "escapes quotes and ampersands" do
    template = described_class.new("<p><%= value %></p>")

    result = template.render(value: %(a & b "c" 'd'))

    expect(result).to eq(%(<p>a &amp; b &quot;c&quot; &#39;d&#39;</p>))
  end

  it "emits raw markup only through the explicit <%== %> tag" do
    template = described_class.new("<div><%== fragment %></div>")

    result = template.render(fragment: "<b>bold</b>")

    expect(result).to eq("<div><b>bold</b></div>")
  end

  it "renders loops and conditionals" do
    template = described_class.new("<ul><% items.each do |i| %><li><%= i %></li><% end %></ul>")

    result = template.render(items: ["a", "<x>"])

    expect(result).to eq("<ul><li>a</li><li>&lt;x&gt;</li></ul>")
  end

  it "renders again with the same local names" do
    template = described_class.new("<p><%= name %></p>")

    expect(template.render(name: "a")).to eq("<p>a</p>")
    expect(template.render(name: "b")).to eq("<p>b</p>")
  end

  it "renders with a different set of local names" do
    template = described_class.new("<p><%= defined?(extra) ? extra : name %></p>")

    expect(template.render(name: "a")).to eq("<p>a</p>")
    expect(template.render(name: "a", extra: "b")).to eq("<p>b</p>")
  end

  it "renders with no locals" do
    expect(described_class.new("<p>hi</p>").render).to eq("<p>hi</p>")
  end

  it "accepts string keys, and a later key wins over the same name as a symbol" do
    template = described_class.new("<p><%= name %></p>")

    expect(template.render("name" => "a")).to eq("<p>a</p>")
    expect(template.render(:name => "a", "name" => "b")).to eq("<p>b</p>")
  end

  it "ignores a local named with a Ruby keyword" do
    template = described_class.new("<p><%= name %></p>")

    expect(template.render(name: "a", class: "b")).to eq("<p>a</p>")
  end

  it "raises NameError for a name that cannot be a local variable" do
    template = described_class.new("<p></p>")

    expect { template.render("not-a-name": 1) }.to raise_error(NameError)
  end

  it "does not expose the template object to the template" do
    template = described_class.new("<%= instance_variable_get(:@src).inspect %>")

    expect(template.render).to eq("nil")
  end
end
