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
end
