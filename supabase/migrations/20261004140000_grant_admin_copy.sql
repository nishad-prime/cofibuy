-- Re-grant EXECUTE on api.admin_copy to authenticated after the admin_set_copy
-- replacement in 20261004130000 (which only re-granted admin_set_copy).
grant execute on function api.admin_copy() to authenticated;