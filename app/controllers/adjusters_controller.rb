# Every adjuster's licensing, skills, load and status.
class AdjustersController < ApplicationController
  def index
    @adjusters = Adjuster.order(:id)
  end
end
