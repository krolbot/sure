# Shared helpers for holding calculators (ForwardCalculator / ReverseCalculator).
# Expects the including class to expose an `account` reader.
module Holding::TradeCalculatorHelpers
  private
    # Converts a trade price at the trade date. Missing rates remain an explicit
    # ConversionError; callers mark the affected cost basis unknown.
    def converted_trade_price(trade, date:)
      Money.new(trade.price, trade.currency).exchange_to(account.currency, date:).amount
    end
end
