-- \connect lega

-- We use schemas for isolation instead of multiple databases.
-- Look at the grants.sql file, for access user/role rights setup

CREATE SCHEMA local_ega; -- includes the main table, some views and errors

SET search_path TO local_ega;

CREATE TYPE checksum_algorithm AS ENUM ('MD5', 'SHA256', 'SHA384', 'SHA512'); -- md5 is bad. Use sha*!
CREATE TYPE storage AS ENUM ('S3', 'POSIX');
-- Note: This is an enum, because that's what the "provided" database supports
--       If a site has its own database already, let them define their keyword in the ENUM 
--       and use it (Notice that their code must be update to push this value into the table)
--       There is no need to agree on how each site should operate their own database
--       What we need is to document where they need to update and what.

CREATE TABLE  local_ega.dbschema_version (
       version     INTEGER,
       applied     TIMESTAMP WITH TIME ZONE,
       description VARCHAR(1024),
       PRIMARY KEY(version), UNIQUE (version)
);

INSERT INTO local_ega.dbschema_version
VALUES (0, now(), 'Created with version'),
       (1, now(), 'Noop version'),
       (2, now(), 'Added decrypted_checksum et al'),
       (3, now(), 'Reorganized out views/tables');

-- ##################################################
--                  FILE STATUS
-- ##################################################
CREATE TABLE local_ega.status (
        id            INTEGER,
	code          VARCHAR(16) NOT NULL,
	description   TEXT,
	-- contraints
	PRIMARY KEY(id), UNIQUE (id), UNIQUE (code)
);

INSERT INTO local_ega.status(id,code,description)
VALUES (10, 'INIT'        , 'Initializing a file ingestion'),
       (20, 'IN_INGESTION', 'Currently under ingestion'),
       (30, 'ARCHIVED'    , 'File moved to Archive'),
       (40, 'COMPLETED'   , 'File verified in Archive'),
       (50, 'READY'       , 'File ingested, ready for download'),
       -- (60, 'IN_INDEXING', 'Currently under index creation'),
       (0, 'ERROR'        , 'An Error occured, check the error table'),
       (1, 'DISABLED'     , 'Used for submissions that are stopped, overwritten, or to be cleaned up')
;

-- ##################################################
--                ENCRYPTION FORMAT
-- ##################################################
CREATE TABLE local_ega.archive_encryption (
       mode          VARCHAR(16) NOT NULL, PRIMARY KEY(mode), UNIQUE (mode),
       description   TEXT
);

INSERT INTO local_ega.archive_encryption(mode,description)
VALUES ('CRYPT4GH'  , 'Crypt4GH encryption (using version)'),
       ('PGP'       , 'OpenPGP encryption (RFC 4880)'),
       ('AES'       , 'AES encryption with passphrase'),
       ('CUSTOM1'   , 'Custom method 1 for local site'),
       ('CUSTOM2'   , 'Custom method 2 for local site')
    -- ...
;

-- ##################################################
--                        FILES
-- ##################################################
-- Main table with looooots of information
CREATE TABLE local_ega.main (
       id                        SERIAL, PRIMARY KEY(id), UNIQUE (id),

       -- EGA file ids
       stable_id                 TEXT,

       -- Status
       status                    VARCHAR NOT NULL REFERENCES local_ega.status (code), -- No "ON DELETE CASCADE":
       				 	     	  	     		      	      -- update to the new status
                                                                            	      -- in case the old one is deleted
       -- Original/Submission file
       submission_file_path                     TEXT NOT NULL,
       submission_file_extension                VARCHAR(260) NOT NULL,
       submission_file_calculated_checksum      VARCHAR(128),
       submission_file_calculated_checksum_type checksum_algorithm,

       submission_file_size                     BIGINT NULL,
       submission_user                          TEXT NOT NULL, -- Elixir ID, or internal user
 
       -- Archive information
       archive_file_reference      TEXT,    -- file path if POSIX, object id if S3
       archive_file_type           storage, -- S3 or POSIX file system
       archive_file_size           BIGINT,
       archive_file_checksum       VARCHAR(128) NULL, -- NOT NULL,
       archive_file_checksum_type  checksum_algorithm,

       -- Decrypted file information
       decrypted_file_size          BIGINT,
       decrypted_file_checksum      VARCHAR(128),
       decrypted_file_checksum_type checksum_algorithm,

       -- Encryption/Decryption
       encryption_method         VARCHAR REFERENCES local_ega.archive_encryption (mode), -- ON DELETE CASCADE,
       version                   INTEGER , -- DEFAULT 1, -- Crypt4GH version
       header                    TEXT,              -- Crypt4GH header
       -- Note: We can support multiple encryption formats. See at the end of that file.

       -- Table Audit / Logs
       created_by                NAME DEFAULT CURRENT_USER, -- Postgres users
       last_modified_by          NAME DEFAULT CURRENT_USER, --
       created_at                TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT clock_timestamp(),
       last_modified             TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT clock_timestamp()
);
CREATE UNIQUE INDEX file_id_idx ON local_ega.main(id);


-- When there is an updated, remember the timestamp
CREATE FUNCTION main_updated()
RETURNS TRIGGER AS $main_updated$
BEGIN
     NEW.last_modified = clock_timestamp();
		 RETURN NEW;
END;
$main_updated$ LANGUAGE plpgsql;

CREATE TRIGGER main_updated AFTER UPDATE ON local_ega.main FOR EACH ROW EXECUTE PROCEDURE main_updated();

-- ##################################################
--              Session Keys Checksums
-- ##################################################
-- To keep track of already used session keys,
-- we record their checksum
CREATE TABLE local_ega.session_key_checksums_sha256 (
       session_key_checksum      VARCHAR(128) NOT NULL, PRIMARY KEY(session_key_checksum), UNIQUE (session_key_checksum),
       session_key_checksum_type checksum_algorithm,
       file_id                   INTEGER NOT NULL REFERENCES local_ega.main(id) ON DELETE CASCADE
);


-- Returns if the session key checksums are already found in the database
CREATE FUNCTION check_session_keys_checksums_sha256(checksums text[]) --local_ega.session_key_checksums.session_key_checksum%TYPE []
    RETURNS boolean AS $check_session_keys_checksums_sha256$
    #variable_conflict use_column
    BEGIN
	RETURN EXISTS(SELECT 1
                      FROM local_ega.session_key_checksums_sha256 sk 
	              INNER JOIN local_ega.files f
		      ON f.id = sk.file_id 
		      WHERE (f.status <> 'ERROR' AND f.status <> 'DISABLED') AND -- no data-race on those values
		      	    sk.session_key_checksum = ANY(checksums));
    END;
$check_session_keys_checksums_sha256$ LANGUAGE plpgsql;


-- ##################################################
--                      ERRORS
-- ##################################################
CREATE TABLE local_ega.main_errors (
        id            SERIAL, PRIMARY KEY(id), UNIQUE (id),
	active        BOOLEAN NOT NULL DEFAULT TRUE,
	file_id       INTEGER NOT NULL REFERENCES local_ega.main(id) ON DELETE CASCADE,
	hostname      TEXT,
	error_type    TEXT NOT NULL,
	msg           TEXT NOT NULL,
	from_user     BOOLEAN DEFAULT FALSE,
	occured_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT clock_timestamp()
);


-- ##################################################
--         Data-In View
-- ##################################################
-- 
CREATE VIEW local_ega.files AS
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
       decrypted_file_size			  AS decrypted_file_size,
       decrypted_file_checksum			  AS decrypted_file_checksum,
       decrypted_file_checksum_type		  AS decrypted_file_checksum_type,
       stable_id,
       header,  -- Crypt4gh specific
       version,
       created_at,
       last_modified
FROM local_ega.main;

-- Insert into main
CREATE FUNCTION insert_file(inpath        local_ega.main.submission_file_path%TYPE,
			    eid           local_ega.main.submission_user%TYPE)
RETURNS local_ega.main.id%TYPE AS $insert_file$
    #variable_conflict use_column
    DECLARE
        file_id  local_ega.main.id%TYPE;
        file_ext local_ega.main.submission_file_extension%TYPE;
    BEGIN
        -- Make a new insertion
        file_ext := substring(inpath from '\.([^\.]*)$'); -- extract extension from filename
	INSERT INTO local_ega.main (submission_file_path,
	  	                    submission_user,
			   	    submission_file_extension,
			  	    status,
			  	    encryption_method) -- hard-code the archive_encryption
	VALUES(inpath,eid,file_ext,'INIT','CRYPT4GH') RETURNING local_ega.main.id
	INTO file_id;
	RETURN file_id;
    END;
$insert_file$ LANGUAGE plpgsql;

-- Flag as READY, and mark older ingestion as deprecated (to clean up)
CREATE FUNCTION finalize_file(inpath        local_ega.files.inbox_path%TYPE,
			      eid           local_ega.files.elixir_id%TYPE,
			      checksum      local_ega.files.archive_file_checksum%TYPE,
			      checksum_type VARCHAR, -- local_ega.files.archive_file_checksum_type%TYPE,
			      sid           local_ega.files.stable_id%TYPE)
    RETURNS void AS $finalize_file$
    #variable_conflict use_column
    BEGIN
	-- -- Check if in proper state
	-- IF EXISTS(SELECT id
	--    	  FROM local_ega.main
	-- 	  WHERE archive_file_checksum = checksum AND
	-- 	  	archive_file_checksum_type = upper(checksum_type)::local_ega.checksum_algorithm AND
	-- 		elixir_id = eid AND
	-- 		inbox_path = inpath AND
	-- 		status <> 'COMPLETED')
	-- THEN
	--    RAISE EXCEPTION 'Archive file not in completed state for stable_id: % ', sid;
	-- END IF;
	-- Go ahead and mark _them_ done
	UPDATE local_ega.files
	SET status = 'READY',
	    stable_id = sid
	WHERE archive_file_checksum = checksum AND
	      archive_file_checksum_type = upper(checksum_type)::local_ega.checksum_algorithm AND
	      elixir_id = eid AND
	      inbox_path = inpath AND
	      status = 'COMPLETED';
    END;
$finalize_file$ LANGUAGE plpgsql;

-- If the entry is marked disabled, it says disabled. No data race here.
CREATE FUNCTION is_disabled(fid local_ega.main.id%TYPE)
RETURNS boolean AS $is_disabled$
#variable_conflict use_column
BEGIN
   RETURN EXISTS(SELECT 1 FROM local_ega.files WHERE id = fid AND status = 'DISABLED');
END;
$is_disabled$ LANGUAGE plpgsql;


-- Just showing the current/active errors
CREATE VIEW local_ega.errors AS
SELECT id, file_id, hostname, error_type, msg, from_user, occured_at
FROM local_ega.main_errors
WHERE active = TRUE;

CREATE FUNCTION insert_error(fid        local_ega.errors.file_id%TYPE,
                             h          local_ega.errors.hostname%TYPE,
                             etype      local_ega.errors.error_type%TYPE,
                             msg        local_ega.errors.msg%TYPE,
                             from_user  local_ega.errors.from_user%TYPE)
    RETURNS void AS $insert_error$
    BEGIN
       INSERT INTO local_ega.errors (file_id,hostname,error_type,msg,from_user) VALUES(fid,h,etype,msg,from_user);
       UPDATE local_ega.files SET status = 'ERROR' WHERE id = fid;
    END;
$insert_error$ LANGUAGE plpgsql;


-- When File becomes 'READY', remove all its errors from current errors.
CREATE FUNCTION mark_ready()
RETURNS TRIGGER AS $mark_ready$
BEGIN
     UPDATE local_ega.main_errors SET active = FALSE WHERE file_id = NEW.id;  -- or OLD.id
     RETURN NEW;
END;
$mark_ready$ LANGUAGE plpgsql;

CREATE TRIGGER mark_ready 
    AFTER UPDATE OF status ON local_ega.main -- using the main and not files
                                             -- because "Views cannot have row-level BEFORE or AFTER triggers."
    FOR EACH ROW WHEN (NEW.status = 'READY')
    EXECUTE PROCEDURE mark_ready();




-- ##########################################################################
--           For data-out
-- ##########################################################################

-- View on the archive files
CREATE VIEW local_ega.archive_files AS
SELECT id                        AS file_id
     , stable_id                 AS stable_id
     , archive_file_reference      AS archive_path
     , archive_file_type           AS archive_type
     , archive_file_size           AS archive_filesize
     , archive_file_checksum       AS archive_file_checksum
     , archive_file_checksum_type  AS archive_file_checksum_type
     , header                    AS header
     , version                   AS version
FROM local_ega.main
WHERE status = 'READY';
-- ##########################################################################
--                   About the encryption
-- ##########################################################################
-- 
-- 
-- We can support multiple encryption types in the archive
-- (Say, for example, Crypt4GH, PGP and plain AES),
-- in the following manner:
-- 
-- We create a table for each method of encryption.
-- Each table will have its own set of fields, refering to data it needs for decryption
-- 
-- Then we update the main file table with a archive_encryption "keyword".
-- That will tell the main file table to look at another table for that
-- particular file. (Note that this file reference is found in only one
-- encryption table).
--
-- At the moment, we added the whole Crypt4gh-related table inside the main table.
-- That's easily changeable, using views.
-- 
-- The site that wants to support multiple encryption methods must update the data-in and
-- data-out code in order to push/pull the data accordingly.
