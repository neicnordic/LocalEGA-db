
DO
$$
DECLARE
-- The version we know how to do migration from, at the end of a successful migration
-- we will no longer be at this version.
  sourcever INTEGER := 1;
  changes VARCHAR := 'Add columns for decrypted checksum ';
BEGIN
-- No explicit transaction handling here, this all happens in a transaction 
-- automatically 
  IF (select max(version) from local_ega.dbschema_version) = sourcever then
    RAISE NOTICE 'Doing migration from schema version % to %', sourcever, sourcever+1;
    RAISE NOTICE 'Changes: %', changes;
    INSERT INTO local_ega.dbschema_version VALUES(sourcever+1, now(), changes);
    CREATE OR REPLACE VIEW local_ega.files AS
    SELECT id,
       submission_user                          AS elixir_id,
       submission_file_path                     AS inbox_path,
       submission_file_size                     AS inbox_filesize,
       submission_file_calculated_checksum      AS inbox_file_checksum,
       submission_file_calculated_checksum_type AS inbox_file_checksum_type,
       status,
       archive_file_reference                     AS archive_path,
       archive_file_type                          AS archive_type,
       archive_file_size                          AS archive_filesize,
       archive_file_checksum                      AS archive_file_checksum,
       archive_file_checksum_type                 AS archive_file_checksum_type,
       decrypted_file_checksum			  AS decrypted_file_checksum,
       decrypted_file_checksum_type		  AS decrypted_file_checksum_type,
       stable_id,
       header,  -- Crypt4gh specific
       version,
       created_at,
       last_modified
     FROM local_ega.main;

  ELSE
    RAISE NOTICE 'Schema migration from % to % does not apply now, skipping', sourcever, sourcever+1;
  END IF;
END
$$


