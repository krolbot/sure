class Holding::ReverseCalculator
  include Holding::TradeCalculatorHelpers

  attr_reader :account, :portfolio_snapshot

  def initialize(account, portfolio_snapshot:, security_ids: nil)
    @account = account
    @portfolio_snapshot = portfolio_snapshot
    @security_ids = security_ids
  end

  def calculate
    Rails.logger.tagged("Holding::ReverseCalculator") do
      precompute_cost_basis
      holdings = calculate_holdings
      Holding.gapfill(holdings)
    end
  end

  private
    def portfolio_cache
      @portfolio_cache ||= Holding::PortfolioCache.new(account, use_holdings: true, security_ids: @security_ids)
    end

    def calculate_holdings
      current_portfolio = portfolio_snapshot.to_h
      previous_portfolio = {}
      holdings = []

      Date.current.downto(account.start_date).each do |date|
        today_trades = portfolio_cache.get_trades(date: date)
        previous_portfolio = transform_portfolio(current_portfolio, today_trades, direction: :reverse)
        holdings.concat(build_holdings(current_portfolio, date, price_source: date == Date.current ? "holding" : nil))
        current_portfolio = previous_portfolio
      end

      holdings
    end

    def transform_portfolio(previous_portfolio, trade_entries, direction: :forward)
      new_quantities = previous_portfolio.dup

      trade_entries.each do |trade_entry|
        trade = trade_entry.entryable
        qty_change = direction == :reverse ? -trade.qty : trade.qty
        new_quantities[trade.security_id] = (new_quantities[trade.security_id] || 0) + qty_change
      end

      new_quantities
    end

    def build_holdings(portfolio, date, price_source: nil)
      portfolio.map do |security_id, qty|
        next if @security_ids && !@security_ids.include?(security_id)

        price = portfolio_cache.get_price(security_id, date, source: price_source)
        next if price.nil?

        Holding::HoldingData.new(
          account_id: account.id,
          security_id: security_id,
          date: date,
          qty: qty,
          price: price.price,
          currency: price.currency,
          amount: qty * price.price,
          cost_basis: cost_basis_for(security_id, date),
          cost_basis_unknown: cost_basis_unknown?(security_id, date)
        )
      end.compact
    end

    def precompute_cost_basis
      @cost_basis_snapshots = Hash.new { |h, k| h[k] = [] }
      @unknown_spans = Hash.new { |h, k| h[k] = [] }
      trackers = Hash.new { |h, k| h[k] = Holding::CostBasisTracker.new }
      open_unknown_start = {}

      # get_trades is already ordered by date, created_at, and id. Preserve that
      # order because liquidation and same-day repurchase are order-sensitive.
      trades = portfolio_cache.get_trades
      net_qty = Hash.new(0)
      trades.each { |trade_entry| net_qty[trade_entry.entryable.security_id] += trade_entry.entryable.qty }
      snapshot = portfolio_snapshot.to_h
      positions = Hash.new(0)
      net_qty.each_key { |security_id| positions[security_id] = (snapshot[security_id] || 0) - net_qty[security_id] }

      trades.each do |trade_entry|
        trade = trade_entry.entryable
        security_id = trade.security_id
        previous_position = positions[security_id]
        positions[security_id] += trade.qty
        tracker = trackers[security_id]

        if trade.internal_movement?
          if trade.qty.positive?
            open_unknown_start[security_id] ||= trade_entry.date
          else
            tracker.apply(nil, trade.qty)
            @cost_basis_snapshots[security_id] << [ trade_entry.date, tracker.average_cost ]
          end
        elsif trade.qty.positive?
          begin
            tracker.apply(converted_trade_price(trade, date: trade_entry.date), trade.qty)
            @cost_basis_snapshots[security_id] << [ trade_entry.date, tracker.average_cost ]
          rescue Money::ConversionError
            Rails.logger.warn("[Holding::ReverseCalculator] No FX rate for #{trade.currency}→#{account.currency} on #{trade_entry.date}. Cost basis for security #{security_id} is unknown.")
            open_unknown_start[security_id] ||= trade_entry.date
            @cost_basis_snapshots[security_id] << [ trade_entry.date, nil ]
          end
        else
          tracker.apply(nil, trade.qty)
          @cost_basis_snapshots[security_id] << [ trade_entry.date, tracker.average_cost ]
        end

        if open_unknown_start[security_id] && previous_position.positive? && positions[security_id] <= 0
          @unknown_spans[security_id] << [ open_unknown_start[security_id], trade_entry.date ]
          open_unknown_start.delete(security_id)
        end
      end

      open_unknown_start.each { |security_id, start| @unknown_spans[security_id] << [ start, nil ] }
    end

    def cost_basis_unknown?(security_id, date)
      @unknown_spans[security_id].any? { |start, stop| start <= date && (stop.nil? || date < stop) }
    end

    def cost_basis_for(security_id, date)
      return nil if cost_basis_unknown?(security_id, date)

      snapshots = @cost_basis_snapshots[security_id]
      return nil if snapshots.empty?

      lo, hi, result = 0, snapshots.size - 1, nil
      while lo <= hi
        mid = (lo + hi) / 2
        if snapshots[mid][0] <= date
          result = snapshots[mid][1]
          lo = mid + 1
        else
          hi = mid - 1
        end
      end
      result
    end
end
