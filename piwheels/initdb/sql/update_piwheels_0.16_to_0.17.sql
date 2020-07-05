UPDATE configuration SET version = '0.17';

ALTER TABLE packages
    ADD COLUMN description VARCHAR(200) DEFAULT '' NOT NULL;

ALTER TABLE versions
    ADD COLUMN yanked BOOLEAN DEFAULT false NOT NULL,
    DROP CONSTRAINT versions_package_fk,
    ADD CONSTRAINT versions_package_fk FOREIGN KEY (package)
        REFERENCES packages ON DELETE CASCADE;

CREATE TABLE preinstalled_apt_packages (
    abi_tag        VARCHAR(100) NOT NULL,
    apt_package    VARCHAR(255) NOT NULL,

    CONSTRAINT preinstalled_apt_packages_pk PRIMARY KEY (abi_tag, apt_package),
    CONSTRAINT preinstalled_apt_packages_abi_tag_fk FOREIGN KEY (abi_tag)
        REFERENCES build_abis (abi_tag) ON DELETE CASCADE
);

CREATE INDEX preinstalled_apt_packages_abi_tag ON preinstalled_apt_packages(abi_tag);
GRANT SELECT ON preinstalled_apt_packages TO {username};

ALTER TABLE rewrites_pending
    DROP CONSTRAINT rewrites_pending_package_fk;

CREATE FUNCTION delete_package(pkg TEXT)
    RETURNS VOID
    LANGUAGE SQL
    CALLED ON NULL INPUT
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $sql$
    DELETE FROM packages
    WHERE package = pkg;
$sql$;

REVOKE ALL ON FUNCTION delete_package(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION delete_package(TEXT) TO {username};

CREATE FUNCTION delete_version(pkg TEXT, ver TEXT)
    RETURNS VOID
    LANGUAGE SQL
    CALLED ON NULL INPUT
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $sql$
    DELETE FROM versions
    WHERE package = pkg
    AND version = ver;
$sql$;

REVOKE ALL ON FUNCTION delete_version(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION delete_version(TEXT, TEXT) TO {username};

CREATE FUNCTION yank_version(pkg TEXT, ver TEXT)
    RETURNS VOID
    LANGUAGE SQL
    CALLED ON NULL INPUT
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $sql$
    UPDATE versions
    SET yanked = true
    WHERE package = pkg
    AND version = ver;
$sql$;

REVOKE ALL ON FUNCTION yank_version(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION yank_version(TEXT, TEXT) TO {username};

CREATE FUNCTION unyank_version(pkg TEXT, ver TEXT)
    RETURNS VOID
    LANGUAGE SQL
    CALLED ON NULL INPUT
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $sql$
    UPDATE versions
    SET yanked = false
    WHERE package = pkg
    AND version = ver;
$sql$;

REVOKE ALL ON FUNCTION unyank_version(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION unyank_version(TEXT, TEXT) TO {username};

CREATE FUNCTION package_marked_deleted(pkg TEXT)
    RETURNS BOOLEAN
    LANGUAGE SQL
    RETURNS NULL ON NULL INPUT
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $sql$
    SELECT COUNT(*) = 1
    FROM packages
    WHERE package = pkg
    AND skip = 'deleted';
$sql$;

REVOKE ALL ON FUNCTION package_marked_deleted(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION package_marked_deleted(TEXT) TO {username};

CREATE FUNCTION get_versions_deleted(pkg TEXT)
    RETURNS TABLE(
        version versions.version%TYPE
    )
    LANGUAGE SQL
    RETURNS NULL ON NULL INPUT
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $sql$
    SELECT version
    FROM versions
    WHERE package = pkg
    AND skip = 'deleted';
$sql$;

REVOKE ALL ON FUNCTION get_versions_deleted(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_versions_deleted(TEXT) TO {username};

DROP FUNCTION get_file_dependencies(TEXT);

CREATE FUNCTION get_file_apt_dependencies(fn TEXT)
    RETURNS TABLE(
        dependency dependencies.dependency%TYPE
    )
    LANGUAGE SQL
    RETURNS NULL ON NULL INPUT
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $sql$
    SELECT dependency
        FROM dependencies
        WHERE filename = fn
        AND tool = 'apt'
    EXCEPT ALL
    SELECT apt_package
        FROM preinstalled_apt_packages p
        JOIN files f
        ON p.abi_tag = f.abi_tag
        WHERE f.filename = fn;
$sql$;

REVOKE ALL ON FUNCTION get_file_apt_dependencies(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_file_apt_dependencies(TEXT) TO {username};

CREATE FUNCTION update_project_description(pkg TEXT, dsc TEXT)
    RETURNS VOID
    LANGUAGE SQL
    CALLED ON NULL INPUT
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $sql$
    UPDATE packages
    SET description = dsc
    WHERE package = pkg;
$sql$;

REVOKE ALL ON FUNCTION update_project_description(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION update_project_description(TEXT, TEXT) TO {username};

CREATE FUNCTION get_project_description(pkg TEXT)
    RETURNS TEXT
    LANGUAGE SQL
    RETURNS NULL ON NULL INPUT
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $sql$
    SELECT description
    FROM packages
    WHERE package = pkg;
$sql$;

REVOKE ALL ON FUNCTION get_project_description(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_project_description(TEXT) TO {username};

CREATE FUNCTION version_is_prerelease(version TEXT)
    RETURNS BOOLEAN
    LANGUAGE SQL
    RETURNS NULL ON NULL INPUT
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $sql$
    VALUES (LOWER(version) ~* '(a|b|rc|dev|alpha|beta|c|pre|preview)');
$sql$;

REVOKE ALL ON FUNCTION version_is_prerelease(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION version_is_prerelease(TEXT) TO {username};

DROP FUNCTION get_project_versions(TEXT);

CREATE FUNCTION get_project_versions(pkg TEXT)
    RETURNS TABLE(
        version versions.version%TYPE,
        skipped versions.skip%TYPE,
        builds_succeeded TEXT,
        builds_failed TEXT,
        yanked BOOLEAN,
        prerelease BOOLEAN
    )
    LANGUAGE SQL
    RETURNS NULL ON NULL INPUT
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $sql$
    SELECT
        v.version,
        COALESCE(NULLIF(v.skip, ''), p.skip) AS skipped,
        COALESCE(STRING_AGG(DISTINCT b.abi_tag, ', ') FILTER (WHERE b.status), '') AS builds_succeeded,
        COALESCE(STRING_AGG(DISTINCT b.abi_tag, ', ') FILTER (WHERE NOT b.status), '') AS builds_failed,
        v.yanked,
        version_is_prerelease(v.version)
    FROM
        packages p
        JOIN versions v USING (package)
        LEFT JOIN builds b USING (package, version)
    WHERE v.package = pkg
    GROUP BY version, skipped, yanked;
$sql$;

DROP FUNCTION get_project_files(TEXT);

CREATE FUNCTION get_project_files(pkg TEXT)
    RETURNS TABLE(
        version builds.version%TYPE,
        abi_tag files.abi_tag%TYPE,
        filename files.filename%TYPE,
        filesize files.filesize%TYPE,
        filehash files.filehash%TYPE,
        yanked versions.yanked%TYPE
    )
    LANGUAGE SQL
    RETURNS NULL ON NULL INPUT
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $sql$
    SELECT
        b.version,
        f.abi_tag,
        f.filename,
        f.filesize,
        f.filehash,
        v.yanked
    FROM
        builds b
        JOIN files f USING (build_id)
        JOIN versions v USING (package, version)
    WHERE b.status
    AND b.package = pkg;
$sql$;

REVOKE ALL ON FUNCTION get_project_files(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_project_files(TEXT) TO {username};
