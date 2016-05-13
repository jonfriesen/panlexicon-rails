class Search
  include ActiveModel::Model
  attr_reader :string, :words, :parser, :additive_group_ids, :subtractive_group_ids

  validates :string, presence: true
  validate :words_exist
  validate :words_have_intersecting_groups

  MAX_RELATED_WORDS = 80
  MAX_WEIGHT = 6

  def initialize(string)
    @string = string
    @parser = SearchParser.new string
  end

  def execute
    parser.execute
  end

  def fragments
    parser.fragments
  end

  def results
    @results ||= weight_related_words
  end

  def group_ids
    @group_ids ||= begin
      @additive_group_ids = group_ids_for_fragments additive_fragments
      @subtractive_group_ids = group_ids_for_fragments subtractive_fragments

      additive_group_ids - subtractive_group_ids
    end
  end

  def additive_groups
    @additive_groups ||= Group.where(id: additive_group_ids).includes(:key_word)
  end

  def subtractive_groups
    @subtractive_groups ||= Group.where id: subtractive_group_ids
  end

  def missing_words
    parser.missing_words
  end

  private

  def fragments_with_word
    fragments.select { |fragment| fragment.word.present? }
  end

  def additive_fragments
    fragments_with_word.select { |fragment| fragment.operation == :add }
  end

  def subtractive_fragments
    fragments_with_word.select { |fragment| fragment.operation == :subtract }
  end

  def weight_related_words
    # Selects the searched words and sets the weight and searched_groups_count
    # to be the maximum
    select_and_weight_words = """
      SELECT
        words.*,
        :searched_groups_count AS searched_groups_count,
        :max_weight AS groups_count_width_bucket,
        :max_weight AS rank_width_bucket,
        :max_weight AS ntile_bucket
      FROM words
      WHERE words.id IN (:searched_word_ids)
    """

    # Selects the related words but NOT the searched words, calculating the
    # proper weight from the searched_groups_count
    select_and_weight_related_words = """
    WITH
        grouping as (
            SELECT word_id, COUNT(*) as searched_groups_count
            FROM groupings
            WHERE group_id IN (:group_ids)
            GROUP BY word_id ORDER BY searched_groups_count DESC LIMIT :max_related_words
        ),
        grouping_with_rank AS (
            SELECT
                *,
                DENSE_RANK() OVER (ORDER BY searched_groups_count ASC) AS dense_rank
            FROM grouping
        ),
        group_stats as (
            SELECT min(searched_groups_count) AS min_groups_count,
                   max(searched_groups_count) AS max_groups_count,
                   COUNT(DISTINCT(searched_groups_count)) AS count_distinct_groups,
                   max(dense_rank) AS max_dense_rank
            FROM grouping_with_rank
        )

    SELECT
        words.*,
        grouping_with_rank.searched_groups_count,
        -- grouping_with_rank.dense_rank,
        -- group_stats.min_groups_count,
        -- group_stats.max_groups_count,
        -- group_stats.count_distinct_groups,
        -- group_stats.max_dense_rank,
        width_bucket(
            grouping_with_rank.searched_groups_count,
            min_groups_count - 0.001,
            max_groups_count + 0.001,
            :max_weight
        ) AS groups_count_width_bucket,
        width_bucket(
            grouping_with_rank.dense_rank,
            0.999,
            group_stats.max_dense_rank + 0.001,
            :max_weight
        ) AS rank_width_bucket,
        ntile(:max_weight) OVER (ORDER BY grouping_with_rank.searched_groups_count) AS ntile_bucket
      FROM
        grouping_with_rank LEFT JOIN words ON words.id = grouping_with_rank.word_id,
        group_stats
      ORDER BY name ASC
    """

    # Union the two select statements and fetch a collection of words
    searched_word_ids = fragments_with_word.map { |fragment| fragment.word.id }
    Word.find_by_sql ["
      (#{select_and_weight_words}) UNION (#{select_and_weight_related_words})
      ORDER BY name ASC;
    ", {
      max_related_words: MAX_RELATED_WORDS,
      max_weight: MAX_WEIGHT,
      group_ids: group_ids,
      searched_groups_count: group_ids.size,
      searched_word_ids: searched_word_ids
    }]
  end

  def words_exist
    return unless missing_words.size > 0
    errors.add :string, "#{ sadness_synonym.titleize }. "\
                        "The #{ 'word'.pluralize(missing_words.size) } "\
                        "<strong>#{ missing_words.join(', ') }</strong> "\
                        "#{ missing_words.size == 1 ? 'is' : 'are' } not in our dictionary."
  end

  def group_ids_for_fragments(fragments)
    select_group_ids = fragments.map do |fragment|
      word = fragment.word
      g = Grouping.arel_table
      word_in_grouping = g[:word_id].eq(word.id)

      g.project(:group_id).where(word_in_grouping)
    end

    # Intersection should be done in Arel, but currently can't be chained
    # e.g. select_group_ids.inject(&:intersect) doesn't work
    # https://github.com/rails/arel/pull/320
    query = select_group_ids.map(&:to_sql).join ' INTERSECT '
    result = ActiveRecord::Base.connection.execute query
    if result.count > 0
      result.field_values('group_id').map(&:to_i)
    else
      []
    end
  end

  def words_have_intersecting_groups
    return unless group_ids.size == 0
    errors.add :groups, "#{ sadness_synonym.titleize }. "\
                        'No commonality can be found between '\
                        "<strong>#{ string }</strong>."\
  end

  def sadness_synonym
    %w[sadness despair woe anguish ache distress].sample
  end
end
