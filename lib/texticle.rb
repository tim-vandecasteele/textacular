require 'active_record'

module Texticle
  def search(query = "", exclusive = true)
    exclusive, query = munge_exclusive_and_query(exclusive, query)
    parsed_query_hash = parse_query_hash(query)
    similarities, conditions = basic_similarities_and_conditions(parsed_query_hash)
    assemble_query(similarities, conditions, exclusive)
  end

  def advanced_search(query = "", exclusive = true)
    exclusive, query = munge_exclusive_and_query(exclusive, query)
    parsed_query_hash = parse_query_hash(query)
    similarities, conditions = advanced_similarities_and_conditions(parsed_query_hash)
    assemble_query(similarities, conditions, exclusive)
  end

  def method_missing(method, *search_terms)
    return super if self == ActiveRecord::Base
    if Helper.dynamic_search_method?(method, self.columns)
      exclusive = Helper.exclusive_dynamic_search_method?(method, self.columns)
      columns = exclusive ? Helper.exclusive_dynamic_search_columns(method) : Helper.inclusive_dynamic_search_columns(method)
      metaclass = class << self; self; end
      metaclass.__send__(:define_method, method) do |*args|
        query = columns.inject({}) do |query, column|
          query.merge column => args.shift
        end
        search(query, exclusive)
      end
      __send__(method, *search_terms, exclusive)
    else
      super
    end
  rescue ActiveRecord::StatementInvalid
    super
  end

  def respond_to?(method, include_private = false)
    return super if self == ActiveRecord::Base
    Helper.dynamic_search_method?(method, self.columns) or super
  rescue StandardError
    super
  end

  private

  def munge_exclusive_and_query(exclusive, query)
    unless query.is_a?(Hash)
      exclusive = false
      query = searchable_columns.inject({}) do |terms, column|
        terms.merge column => query.to_s
      end
    end

    [exclusive, query]
  end

  def parse_query_hash(query, table_name = quoted_table_name)
    table_name = connection.quote_table_name(table_name)

    results = []

    query.collect do |column_or_table, search_term|
      if search_term.is_a?(Hash)
        results += parse_query_hash(search_term, column_or_table)
      else
        column = connection.quote_column_name(column_or_table)
        search_term = connection.quote normalize(Helper.normalize(search_term))

        [table_name, column, search_term]
      end
    end
  end

  def basic_similarities_and_conditoins(parsed_query_hash)
    parsed_query_hash.inject([]) do |memo, query_args|
      memo << [basic_similarity_string(*query_args), basic_condition_string(*query_args)]
      memo
    end
  end

  def basic_similarity_string(table_name, column, query)
    "ts_rank(to_tsvector(#{quoted_language}, #{table_name}.#{column}::text), plainto_tsquery(#{quoted_language}, #{search_term}::text))"
  end

  def basic_condition_string(table_name, column, query)
    "to_tsvector(#{quoted_language}, #{table_name}.#{column}::text) @@ plainto_tsquery(#{quoted_language}, #{search_term}::text)"
  end

  def advanced_similarities_and_conditoins(parsed_query_hash)
    parsed_query_hash.inject([]) do |memo, query_args|
      memo << [advanced_similarity_string(*query_args), advanced_condition_string(*query_args)]
      memo
    end
  end

  def advanced_similarity_string(table_name, column, query)
    "ts_rank(to_tsvector(#{quoted_language}, #{table_name}.#{column}::text), to_tsquery(#{quoted_language}, #{search_term}::text))"
  end

  def advanced_condition_string(table_name, column, query)
    "to_tsvector(#{quoted_language}, #{table_name}.#{column}::text) @@ to_tsquery(#{quoted_language}, #{search_term}::text)"
  end

  def assemble_query(similarities, conditions, exclusive)
    rank = connection.quote_column_name('rank' + rand.to_s)

    select("#{quoted_table_name + '.*,' if scoped.select_values.empty?} #{similarities.join(" + ")} AS #{rank}").
      where(conditions.join(exclusive ? " AND " : " OR ")).
      order("#{rank} DESC")
  end

  def normalize(query)
    query
  end

  def searchable_columns
    columns.select {|column| [:string, :text].include? column.type }.map(&:name)
  end

  def quoted_language
    @quoted_language ||= connection.quote(searchable_language)
  end

  def searchable_language
    'english'
  end

  module Helper
    class << self
      def normalize(query)
        query.to_s.gsub(' ', '\\\\ ')
      end

      def exclusive_dynamic_search_columns(method)
        if match = method.to_s.match(/^search_by_(?<columns>[_a-zA-Z]\w*)$/)
          match[:columns].split('_and_')
        else
          []
        end
      end

      def inclusive_dynamic_search_columns(method)
        if match = method.to_s.match(/^search_by_(?<columns>[_a-zA-Z]\w*)$/)
          match[:columns].split('_or_')
        else
          []
        end
      end

      def exclusive_dynamic_search_method?(method, class_columns)
        string_columns = class_columns.map(&:name)
        columns = exclusive_dynamic_search_columns(method)
        unless columns.empty?
          columns.all? {|column| string_columns.include?(column) }
        else
          false
        end
      end

      def inclusive_dynamic_search_method?(method, class_columns)
        string_columns = class_columns.map(&:name)
        columns = inclusive_dynamic_search_columns(method)
        unless columns.empty?
          columns.all? {|column| string_columns.include?(column) }
        else
          false
        end
      end

      def dynamic_search_method?(method, class_columns)
        exclusive_dynamic_search_method?(method, class_columns) or
          inclusive_dynamic_search_method?(method, class_columns)
      end
    end
  end
end
