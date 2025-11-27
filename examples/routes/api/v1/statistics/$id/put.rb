Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "Updates an existing statistic"

  endpoint.parameters do |parameters|
    parameters.define :id, in: :path, type: :number, description: "ID of the statistic"
  end

  endpoint.request_body type: :object, description: "Statistic parameters", required: true do |body|
    body.property :statistic, type: :object, required: true, description: "Statistic data" do |statistic|
      statistic.property :auto_scale, type: :boolean, description: "Whether to auto scale the statistic"
      statistic.property :custom_max, type: :number, description: "Custom maximum value"
      statistic.property :custom_min, type: :number, description: "Custom minimum value"
      statistic.property :stat_type, type: :string, description: "Type of statistic"
      statistic.property :data_type, type: :string, description: "Data type"
      statistic.property :decimal_places, type: :number, description: "Number of decimal places"
      statistic.property :description, type: :string, description: "Description of the statistic"
      statistic.property :equation_statistics, type: :array, of: :string, description: "Equation statistics"
      statistic.property :interval, type: :string, description: "Interval of the statistic"
      statistic.property :is_private, type: :boolean, description: "Whether the statistic is private"
      statistic.property :name, type: :string, description: "Name of the statistic"
      statistic.property :tracking, type: :string, description: "Tracking type"
      statistic.property :upside_down, type: :boolean, description: "Whether to invert the values"
      statistic.property :post_ids, type: :array, of: :number, description: "IDs of posts"
      statistic.property :combination_statistics, type: :array, of: :string, description: "Combination statistics"
    end
  end

  endpoint.response 200, type: :object do |response|
    response.property :status, type: :string, description: "Status of the operation"
  end

  endpoint.response 422, type: :object do |response|
    response.property :errors, type: :object, description: "Validation errors"
  end

  endpoint.handler do |request, response|
    response.code = :ok
    response.body = {status: "ok for #{request.params[:id]}"}
  end
end
