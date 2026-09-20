class Holding::ForwardCalculator
  include Holding::TradeCalculatorHelpers

  attr_reader :account

  def initialize(account, security_ids: nil)
    @account = account
    @security_ids = security_ids
    @cost_basis_trackers = Hash.new { |h, k| h[k] = Holding::CostBasisTracker.new }
    @cost_basis_invalid = {}
    @transferred_security_ids = Set.new
  end

  def calculate
    Rails.logger.tagged("Holding::ForwardCalculator") do
      current_portfolio = generate_starting_portfolio
      next_portfolio = {}
      holdings = []

      account.start_date.upto(Date.current).each do |date|
        trades = portfolio_cache.get_trades(date: date)
        next_portfolio = apply_trades(current_portfolio, trades)
        holdings.concat(build_holdings(next_portfolio, date))
        current_portfolio = next_portfolio
      end

      Holding.gapfill(holdings)
    end
  end

  private
    def portfolio_cache
      @portfolio_cache ||= Holding::PortfolioCache.new(account, security_ids: @security_ids)
    end

    def empty_portfolio
      securities = portfolio_cache.get_securities
      securities.each_with_object({}) { |security, hash| hash[security.id] = 0 }
    end

    def generate_starting_portfolio
      empty_portfolio
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
          cost_basis: cost_basis_for(security_id),
          cost_basis_unknown: cost_basis_unknown?(security_id)
        )
      end.compact
    end

    # Applies trades in order. A full liquidation clears both transfer- and
    # missing-FX uncertainty, so a later repurchase starts from a clean basis.
    def apply_trades(opening_portfolio, trade_entries)
      portfolio = opening_portfolio.dup

      trade_entries.each do |trade_entry|
        trade = trade_entry.entryable
        security_id = trade.security_id
        previous_quantity = portfolio[security_id] || 0
        tracker = @cost_basis_trackers[security_id]

        if trade.internal_movement?
          trade.qty.positive? ? @transferred_security_ids.add(security_id) : tracker.apply(nil, trade.qty)
        elsif trade.qty.positive?
          begin
            tracker.apply(converted_trade_price(trade, date: trade_entry.date), trade.qty)
          rescue Money::ConversionError
            Rails.logger.warn("[Holding::ForwardCalculator] No FX rate for #{trade.currency}→#{account.currency} on #{trade_entry.date}. Cost basis for security #{security_id} is unknown.")
            @cost_basis_invalid[security_id] = true
          end
        else
          tracker.apply(nil, trade.qty)
        end

        portfolio[security_id] = previous_quantity + trade.qty
        next unless previous_quantity.positive? && portfolio[security_id] <= 0

        @transferred_security_ids.delete(security_id)
        @cost_basis_invalid.delete(security_id)
      end

      portfolio
    end

    def cost_basis_unknown?(security_id)
      @cost_basis_invalid[security_id] || @transferred_security_ids.include?(security_id)
    end

    def cost_basis_for(security_id)
      return nil if cost_basis_unknown?(security_id)

      @cost_basis_trackers[security_id].average_cost
    end
end
