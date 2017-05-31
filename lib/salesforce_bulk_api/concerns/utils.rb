module SalesforceBulkApi::Concerns
  module Utils
    # Saves raw data to a file.
    def save_to_file(data, path)
      open(path, 'wb') { |file| file.write(data) } if path
    end
  end
end
