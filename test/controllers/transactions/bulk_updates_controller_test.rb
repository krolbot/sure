require "test_helper"

class Transactions::BulkUpdatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "bulk update" do
    transactions = @user.family.entries.transactions

    assert_difference [ "Entry.count", "Transaction.count" ], 0 do
      post transactions_bulk_update_url, params: {
        bulk_update: {
          entry_ids: transactions.map(&:id),
          date: 1.day.ago.to_date,
          category_id: Category.second.id,
          merchant_id: Merchant.second.id,
          tag_ids: [ Tag.first.id, Tag.second.id ],
          notes: "Updated note"
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "#{transactions.count} transactions updated", flash[:notice]

    transactions.reload.each do |transaction|
      assert_equal 1.day.ago.to_date, transaction.date
      assert_equal Category.second, transaction.transaction.category
      assert_equal Merchant.second, transaction.transaction.merchant
      assert_equal "Updated note", transaction.notes
      assert_equal [ Tag.first.id, Tag.second.id ], transaction.entryable.tag_ids.sort
    end
  end

  test "bulk update preserves tags when tag_ids not provided" do
    transaction_entry = @user.family.entries.transactions.first
    original_tags = [ Tag.first, Tag.second ]
    transaction_entry.transaction.tags = original_tags
    transaction_entry.transaction.save!

    # Update only the category, without providing tag_ids
    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ transaction_entry.id ],
        category_id: Category.second.id
      }
    }

    assert_redirected_to transactions_url

    transaction_entry.reload
    assert_equal Category.second, transaction_entry.transaction.category
    # Tags should be preserved since tag_ids was not in the request
    assert_equal original_tags.map(&:id).sort, transaction_entry.transaction.tag_ids.sort
  end

  test "bulk update clears tags when tag_ids is blank string array (web multi-select None)" do
    transaction_entry = @user.family.entries.transactions.first
    original_tags = [ Tag.first, Tag.second ]
    transaction_entry.transaction.tags = original_tags
    transaction_entry.transaction.save!

    # For a multiple select, choosing the blank ("None") option submits a blank value.
    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ transaction_entry.id ],
        category_id: Category.second.id,
        tag_ids: [ "" ]
      }
    }

    assert_redirected_to transactions_url

    transaction_entry.reload
    assert_equal Category.second, transaction_entry.transaction.category
    assert_empty transaction_entry.transaction.tags
  end

  test "bulk update clears tags when empty tag_ids explicitly provided (JSON)" do
    transaction_entry = @user.family.entries.transactions.first
    transaction_entry.transaction.tags = [ Tag.first, Tag.second ]
    transaction_entry.transaction.save!

    post transactions_bulk_update_url,
         params: {
           bulk_update: {
             entry_ids: [ transaction_entry.id ],
             category_id: Category.second.id,
             tag_ids: []
           }
         },
         as: :json

    assert_redirected_to transactions_url

    transaction_entry.reload
    assert_equal Category.second, transaction_entry.transaction.category
    assert_empty transaction_entry.transaction.tags
  end

  test "bulk update replaces tags when tag_ids explicitly provided" do
    transaction_entry = @user.family.entries.transactions.first
    transaction_entry.transaction.tags = [ Tag.first ]
    transaction_entry.transaction.save!

    new_tag = Tag.second

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ transaction_entry.id ],
        tag_ids: [ new_tag.id ]
      }
    }

    assert_redirected_to transactions_url

    transaction_entry.reload
    assert_equal [ new_tag.id ], transaction_entry.transaction.tag_ids
  end

  test "member cannot bulk update an unshared account" do
    member = users(:family_member)
    entry = create_transaction_entry(accounts(:investment), name: "Private entry")
    sign_in member

    post transactions_bulk_update_url, params: {
      bulk_update: { entry_ids: [ entry.id ], notes: "must not leak" }
    }

    assert_redirected_to transactions_url
    assert_equal I18n.t("transactions.bulk_updates.permission_error"), flash[:alert]
    assert_nil entry.reload.notes
  end

  test "mixed authorized and unauthorized bulk update is all or nothing" do
    member = users(:family_member)
    writable_entry = create_transaction_entry(accounts(:depository), name: "Writable entry")
    private_entry = create_transaction_entry(accounts(:investment), name: "Private entry")
    sign_in member

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ writable_entry.id, private_entry.id ],
        notes: "must apply nowhere"
      }
    }

    assert_equal I18n.t("transactions.bulk_updates.permission_error"), flash[:alert]
    assert_nil writable_entry.reload.notes
    assert_nil private_entry.reload.notes
  end

  test "read_write share can annotate normalized UUID ids" do
    member = users(:family_member)
    account = accounts(:investment)
    account.share_with!(member, permission: "read_write")
    entry = create_transaction_entry(account, name: "Annotatable entry")
    sign_in member

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ "", entry.id, entry.id ],
        notes: "annotation",
        category_id: Category.second.id
      }
    }

    assert_equal "1 transactions updated", flash[:notice]
    assert_equal "annotation", entry.reload.notes
    assert_equal Category.second, entry.transaction.reload.category
  end

  test "read_write share cannot combine annotations with structural changes" do
    member = users(:family_member)
    account = accounts(:investment)
    account.share_with!(member, permission: "read_write")
    entry = create_transaction_entry(account, name: "Original name")
    original_date = entry.date
    sign_in member

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ entry.id ],
        notes: "must not partially apply",
        date: 2.days.ago.to_date,
        name: "Blocked name"
      }
    }

    assert_equal I18n.t("transactions.bulk_updates.permission_error"), flash[:alert]
    assert_nil entry.reload.notes
    assert_equal original_date, entry.date
    assert_equal "Original name", entry.name
  end

  test "full control share can bulk update structural fields" do
    member = users(:family_member)
    entry = create_transaction_entry(accounts(:depository), name: "Original name")
    sign_in member

    post transactions_bulk_update_url, params: {
      bulk_update: { entry_ids: [ entry.id ], name: "Updated name", date: 2.days.ago.to_date }
    }

    assert_equal "1 transactions updated", flash[:notice]
    assert_equal "Updated name", entry.reload.name
    assert_equal 2.days.ago.to_date, entry.date
  end

  private

    def create_transaction_entry(account, name:)
      account.entries.create!(
        name: name,
        date: Date.current,
        amount: -20,
        currency: account.currency,
        entryable: Transaction.new(kind: "standard")
      )
    end
end
