# == Schema Information
#
# Table name: groups
#
#  id          :integer          not null, primary key
#  key_word_id :integer          not null
#
# Indexes
#
#  index_groups_on_key_word_id  (key_word_id) UNIQUE
#

class Group < ActiveRecord::Base
  belongs_to :key_word, class_name: 'Word'

  has_many :groupings
  has_many :words, through: :groupings

  validates :key_word_id, presence: true, uniqueness: true
end
