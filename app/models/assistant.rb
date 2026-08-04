module Assistant
  Error = Class.new(StandardError)

  REGISTRY = {
    "builtin" => Assistant::Builtin,
    "external" => Assistant::External
  }.freeze

  class << self
    def for_chat(chat)
      implementation_for(chat).for_chat(chat)
    end

    def config_for(chat)
      raise Error, "chat is required" if chat.blank?
      Assistant::Builtin.config_for(chat)
    end

    def available_types
      REGISTRY.keys
    end

    def function_classes
      [
        Function::GetTransactions,
        Function::GetAccounts,
        Function::GetHoldings,
        Function::GetBalanceSheet,
        Function::GetIncomeStatement,
        Function::GetBudget,
        Function::ImportBankStatement,
        Function::SearchFamilyFiles,
        Function::CreateGoal,
        Function::GetTags,
        Function::CreateTag,
        Function::UpdateTag,
        Function::GetCategories,
        Function::CreateCategory,
        Function::UpdateCategory,
        Function::CreateTransaction,
        Function::UpdateTransaction
      ]
    end

    def mcp_function_classes
      function_classes + [
        Function::GetTransfers,
        Function::GetGoals,
        Function::CreateAccount,
        Function::UpdateAccount,
        Function::DeleteAccount,
        Function::DeleteTransaction,
        Function::CreateTransfer,
        Function::UpdateTransfer,
        Function::DeleteTransfer,
        Function::UpdateGoal,
        Function::DeleteGoal,
        Function::DeleteTag,
        Function::DeleteCategory,
        Function::UpdateBudget
      ]
    end

    private

      def implementation_for(chat)
        raise Error, "chat is required" if chat.blank?
        type = ENV["ASSISTANT_TYPE"].presence || chat.user&.family&.assistant_type.presence || "builtin"
        REGISTRY.fetch(type) { REGISTRY["builtin"] }
      end
  end
end
