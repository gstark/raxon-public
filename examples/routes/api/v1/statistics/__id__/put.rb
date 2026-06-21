Raxon.route do
  description "Updates an existing statistic"

  path_param :id, type: :integer, description: "ID of the statistic"

  body type: :object, description: "Statistic parameters", required: true do
    property :statistic, type: :object, required: true, description: "Statistic data" do
      property :auto_scale, type: :boolean, description: "Whether to auto scale the statistic"
      property :custom_max, type: :number, description: "Custom maximum value"
      property :custom_min, type: :number, description: "Custom minimum value"
      property :stat_type, type: :string, description: "Type of statistic"
      property :data_type, type: :string, description: "Data type"
      property :decimal_places, type: :number, description: "Number of decimal places"
      property :description, type: :string, description: "Description of the statistic"
      property :equation_statistics, type: :array, of: :string, description: "Equation statistics"
      property :interval, type: :string, description: "Interval of the statistic"
      property :is_private, type: :boolean, description: "Whether the statistic is private"
      property :name, type: :string, description: "Name of the statistic"
      property :tracking, type: :string, description: "Tracking type"
      property :upside_down, type: :boolean, description: "Whether to invert the values"
      property :post_ids, type: :array, of: :number, description: "IDs of posts"
      property :combination_statistics, type: :array, of: :string, description: "Combination statistics"
    end
  end

  response 200, type: :object do
    property :status, type: :string, description: "Status of the operation"
  end

  error_response :unprocessable_entity, description: "Validation errors" do |response|
    response.property :errors, type: :object, description: "Validation errors"
  end

  handler do |request, response|
    response.ok(status: "ok for #{request.path_params[:id]}")
  end
end
