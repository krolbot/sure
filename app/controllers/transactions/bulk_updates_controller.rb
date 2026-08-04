class Transactions::BulkUpdatesController < ApplicationController
  def new
  end

  def create
    requested_ids = Array(bulk_update_params[:entry_ids]).filter_map { |id| id.to_s.presence }.uniq
    entries = authorized_entries.where(id: requested_ids)

    # Authorize the complete normalized selection before writing anything. This
    # avoids partial mixed-batch updates and keeps inaccessible IDs
    # indistinguishable from missing IDs.
    if entries.count != requested_ids.length
      redirect_back_or_to transactions_path, alert: t(".permission_error")
      return
    end

    updated = entries.bulk_update!(bulk_update_params, update_tags: tags_provided?)

    redirect_back_or_to transactions_path, notice: "#{updated} transactions updated"
  end

  private
    def bulk_update_params
      params.require(:bulk_update)
            .permit(:date, :notes, :name, :category_id, :merchant_id, entry_ids: [], tag_ids: [])
    end

    def authorized_entries
      account_ids = structural_update? ? writable_account_ids : annotatable_account_ids
      Current.family.entries.excluding_split_parents.where(account_id: account_ids)
    end

    def writable_account_ids
      Current.family.accounts.writable_by(Current.user).select(:id)
    end

    def annotatable_account_ids
      Current.family.accounts.annotatable_by(Current.user).select(:id)
    end

    def structural_update?
      bulk_update_params.slice(:date, :name).compact_blank.present?
    end

    # Check if tag_ids was explicitly provided in the request.
    # This distinguishes between "user wants to update tags" vs "user didn't touch tags field".
    def tags_provided?
      bulk_update = params[:bulk_update]
      bulk_update.respond_to?(:key?) && bulk_update.key?(:tag_ids)
    end
end
