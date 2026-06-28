# Throwaway Phase 0 status probe: a bare JSON read proving the ping loop moved
# the timestamps. No auth this phase (Phase 1 replaces it with the authenticated
# dashboard/detail). Deliberately exposes only the documented fields.
class MonitorsController < ApplicationController
  def show
    monitor = Monitoring::Monitor.find(params[:id])

    render json: monitor.slice(:id, :name, :status, :last_ping_at, :next_due_at)
  end
end
