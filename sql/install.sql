-- fks-companies · database schema
-- The resource also runs this file on start (CREATE TABLE IF NOT EXISTS), so importing it by hand is optional.
-- Every statement ends with ";" at the end of a line - server/db.lua splits the file on that.

CREATE TABLE IF NOT EXISTS `fks_companies` (
    `id`               INT(11) NOT NULL AUTO_INCREMENT,
    `code`             VARCHAR(32) NOT NULL,                       -- internal identification (unique, e.g. VAL-SALOON)
    `name`             VARCHAR(64) NOT NULL,
    `job`              VARCHAR(60) NOT NULL,                       -- framework job of the employees
    `description`      VARCHAR(255) NULL,
    `owner_cid`        VARCHAR(60) NULL,                           -- persistent character id (VORP charidentifier / RSG citizenid)
    `owner_name`       VARCHAR(80) NULL,
    `x`                DOUBLE NOT NULL,
    `y`                DOUBLE NOT NULL,
    `z`                DOUBLE NOT NULL,
    `heading`          FLOAT NOT NULL DEFAULT 0,
    `blip`             BIGINT NOT NULL DEFAULT 819673798,
    `balance`          DECIMAL(14,2) NOT NULL DEFAULT 0,
    `total_income`     DECIMAL(14,2) NOT NULL DEFAULT 0,
    `total_expenses`   DECIMAL(14,2) NOT NULL DEFAULT 0,
    `max_employees`    INT(11) NOT NULL DEFAULT 15,
    `status`           ENUM('active','inactive','suspended') NOT NULL DEFAULT 'active',
    `status_reason`    VARCHAR(255) NULL,
    `status_changed_at` INT(11) NULL,
    -- automatic taxes
    `tax_enabled`      TINYINT(1) NOT NULL DEFAULT 0,
    `tax_type`         ENUM('fixed','percent') NOT NULL DEFAULT 'fixed',
    `tax_amount`       DECIMAL(14,2) NOT NULL DEFAULT 0,
    `tax_interval`     INT(11) NOT NULL DEFAULT 1440,               -- minutes
    `tax_next_at`      INT(11) NULL,                               -- unix time of the next collection
    `tax_failures`     INT(11) NOT NULL DEFAULT 0,                 -- consecutive failed collections
    -- storages (slots / weight depend on the inventory; vorp uses slots as item capacity)
    `boss_slots`       INT(11) NOT NULL DEFAULT 50,
    `boss_weight`      INT(11) NOT NULL DEFAULT 100000,
    `general_slots`    INT(11) NOT NULL DEFAULT 100,
    `general_weight`   INT(11) NOT NULL DEFAULT 200000,
    -- store
    `store_enabled`    TINYINT(1) NOT NULL DEFAULT 0,
    `store_model`      VARCHAR(60) NULL,
    -- marketplace
    `sale_status`      ENUM('not_for_sale','for_sale','pending','sold') NOT NULL DEFAULT 'not_for_sale',
    `sale_price`       DECIMAL(14,2) NOT NULL DEFAULT 0,
    `sale_negotiable`  TINYINT(1) NOT NULL DEFAULT 0,
    `sale_public`      TINYINT(1) NOT NULL DEFAULT 1,
    `sale_seller_cid`  VARCHAR(60) NULL,                           -- NULL = listed by the administration (nobody gets paid)
    `sale_listed_at`   INT(11) NULL,
    `created_by`       VARCHAR(80) NULL,
    `created_at`       INT(11) NOT NULL,
    `deleted_at`       INT(11) NULL,                               -- deleted companies are archived, not erased
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_code` (`code`),
    KEY `idx_owner` (`owner_cid`),
    KEY `idx_deleted` (`deleted_at`),
    KEY `idx_sale` (`sale_status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `fks_company_positions` (
    `id`           INT(11) NOT NULL AUTO_INCREMENT,
    `company_id`   INT(11) NOT NULL,
    `name`         VARCHAR(40) NOT NULL,
    `grade`        INT(11) NOT NULL,                               -- framework job grade
    `is_boss`      TINYINT(1) NOT NULL DEFAULT 0,
    `description`  VARCHAR(255) NULL,
    `permissions`  LONGTEXT NULL,                                  -- JSON { permission = true }
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_grade` (`company_id`, `grade`),
    CONSTRAINT `fk_positions_company` FOREIGN KEY (`company_id`) REFERENCES `fks_companies` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `fks_company_employees` (
    `id`            INT(11) NOT NULL AUTO_INCREMENT,
    `company_id`    INT(11) NOT NULL,
    `cid`           VARCHAR(60) NOT NULL,
    `active_cid`    VARCHAR(60) NULL,                              -- = cid while employed, NULL once terminated (one job per character)
    `name`          VARCHAR(80) NOT NULL,
    `position_id`   INT(11) NULL,
    `contract_id`   INT(11) NULL,
    `status`        ENUM('active','terminated') NOT NULL DEFAULT 'active',
    `hired_at`      INT(11) NOT NULL,
    `terminated_at` INT(11) NULL,
    `terminated_by` VARCHAR(80) NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_active_cid` (`active_cid`),
    KEY `idx_company` (`company_id`, `status`),
    KEY `idx_cid` (`cid`),
    CONSTRAINT `fk_employees_company` FOREIGN KEY (`company_id`) REFERENCES `fks_companies` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `fks_company_contracts` (
    `id`             INT(11) NOT NULL AUTO_INCREMENT,
    `token`          VARCHAR(40) NOT NULL,
    `company_id`     INT(11) NOT NULL,
    `employer_cid`   VARCHAR(60) NOT NULL,
    `employer_name`  VARCHAR(80) NOT NULL,
    `employee_cid`   VARCHAR(60) NOT NULL,
    `employee_name`  VARCHAR(80) NOT NULL,
    `position_id`    INT(11) NOT NULL,
    `position_name`  VARCHAR(40) NOT NULL,
    `description`    VARCHAR(500) NULL,
    `status`         ENUM('pending','signed','declined','expired','cancelled','terminated') NOT NULL DEFAULT 'pending',
    `signature`      VARCHAR(80) NULL,
    `created_at`     INT(11) NOT NULL,
    `expires_at`     INT(11) NOT NULL,
    `signed_at`      INT(11) NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_token` (`token`),
    KEY `idx_company` (`company_id`),
    KEY `idx_employee` (`employee_cid`, `status`),
    CONSTRAINT `fk_contracts_company` FOREIGN KEY (`company_id`) REFERENCES `fks_companies` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `fks_company_locations` (
    `company_id`  INT(11) NOT NULL,
    `kind`        ENUM('boss_storage','general_storage','register','store') NOT NULL,
    `x`           DOUBLE NOT NULL,
    `y`           DOUBLE NOT NULL,
    `z`           DOUBLE NOT NULL,
    `heading`     FLOAT NOT NULL DEFAULT 0,
    `model`       VARCHAR(60) NULL,
    `updated_at`  INT(11) NOT NULL,
    PRIMARY KEY (`company_id`, `kind`),
    CONSTRAINT `fk_locations_company` FOREIGN KEY (`company_id`) REFERENCES `fks_companies` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `fks_company_transactions` (
    `id`              INT(11) NOT NULL AUTO_INCREMENT,
    `company_id`      INT(11) NOT NULL,
    `type`            VARCHAR(24) NOT NULL,                        -- deposit | withdraw | expense | tax | tax_failed | register | refund | store | purchase | sale
    `amount`          DECIMAL(14,2) NOT NULL,                      -- signed: + income, - expense
    `balance_before`  DECIMAL(14,2) NOT NULL,
    `balance_after`   DECIMAL(14,2) NOT NULL,
    `actor_cid`       VARCHAR(60) NULL,
    `actor_name`      VARCHAR(80) NULL,
    `description`     VARCHAR(255) NULL,
    `created_at`      INT(11) NOT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_company` (`company_id`, `id`),
    KEY `idx_type` (`type`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `fks_company_activity` (
    `id`          INT(11) NOT NULL AUTO_INCREMENT,
    `company_id`  INT(11) NOT NULL,
    `kind`        VARCHAR(32) NOT NULL,
    `actor_cid`   VARCHAR(60) NULL,
    `actor_name`  VARCHAR(80) NULL,
    `message`     VARCHAR(255) NOT NULL,
    `created_at`  INT(11) NOT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_company` (`company_id`, `id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `fks_company_admin_log` (
    `id`           INT(11) NOT NULL AUTO_INCREMENT,
    `company_id`   INT(11) NULL,
    `company_name` VARCHAR(64) NULL,
    `admin_id`     VARCHAR(80) NULL,                               -- license / identifier of the administrator
    `admin_name`   VARCHAR(80) NOT NULL,
    `action`       VARCHAR(32) NOT NULL,
    `details`      VARCHAR(500) NULL,
    `created_at`   INT(11) NOT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_company` (`company_id`),
    KEY `idx_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `fks_company_purchases` (
    `id`          INT(11) NOT NULL AUTO_INCREMENT,
    `company_id`  INT(11) NOT NULL,
    `kind`        VARCHAR(16) NOT NULL,                            -- name | blip
    `old_value`   VARCHAR(80) NULL,
    `new_value`   VARCHAR(80) NOT NULL,
    `price`       DECIMAL(14,2) NOT NULL,
    `actor_cid`   VARCHAR(60) NULL,
    `actor_name`  VARCHAR(80) NULL,
    `created_at`  INT(11) NOT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_company` (`company_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `fks_company_sales` (
    `id`             INT(11) NOT NULL AUTO_INCREMENT,
    `company_id`     INT(11) NOT NULL,
    `company_name`   VARCHAR(64) NOT NULL,
    `seller_cid`     VARCHAR(60) NULL,                             -- NULL = sold by the administration
    `seller_name`    VARCHAR(80) NULL,
    `buyer_cid`      VARCHAR(60) NOT NULL,
    `buyer_name`     VARCHAR(80) NOT NULL,
    `price`          DECIMAL(14,2) NOT NULL,
    `created_at`     INT(11) NOT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_company` (`company_id`),
    KEY `idx_seller` (`seller_cid`),
    KEY `idx_buyer` (`buyer_cid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `fks_company_payouts` (
    `id`          INT(11) NOT NULL AUTO_INCREMENT,
    `sale_id`     INT(11) NOT NULL,                                -- one payout per sale (no double payments)
    `company_id`  INT(11) NOT NULL,
    `seller_cid`  VARCHAR(60) NOT NULL,
    `amount`      DECIMAL(14,2) NOT NULL,
    `status`      ENUM('pending','paid') NOT NULL DEFAULT 'pending',
    `method`      VARCHAR(16) NULL,                                -- online | offline | login
    `created_at`  INT(11) NOT NULL,
    `paid_at`     INT(11) NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_sale` (`sale_id`),
    KEY `idx_seller` (`seller_cid`, `status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `fks_company_products` (
    `id`              INT(11) NOT NULL AUTO_INCREMENT,
    `company_id`      INT(11) NOT NULL,
    `item`            VARCHAR(80) NOT NULL,
    `label`           VARCHAR(80) NOT NULL,
    `quantity`        INT(11) NOT NULL DEFAULT 0,
    `price`           DECIMAL(14,2) NOT NULL,
    `description`     VARCHAR(255) NULL,
    `listed_by_cid`   VARCHAR(60) NULL,
    `listed_by_name`  VARCHAR(80) NULL,
    `listed_at`       INT(11) NOT NULL,
    `updated_at`      INT(11) NOT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_item` (`company_id`, `item`),
    CONSTRAINT `fk_products_company` FOREIGN KEY (`company_id`) REFERENCES `fks_companies` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `fks_company_store_sales` (
    `id`             INT(11) NOT NULL AUTO_INCREMENT,
    `company_id`     INT(11) NOT NULL,
    `customer_cid`   VARCHAR(60) NOT NULL,
    `customer_name`  VARCHAR(80) NOT NULL,
    `total`          DECIMAL(14,2) NOT NULL,
    `status`         ENUM('completed','rolled_back') NOT NULL DEFAULT 'completed',
    `created_at`     INT(11) NOT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_company` (`company_id`),
    KEY `idx_customer` (`customer_cid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `fks_company_store_sale_items` (
    `id`        INT(11) NOT NULL AUTO_INCREMENT,
    `sale_id`   INT(11) NOT NULL,
    `item`      VARCHAR(80) NOT NULL,
    `label`     VARCHAR(80) NOT NULL,
    `quantity`  INT(11) NOT NULL,
    `price`     DECIMAL(14,2) NOT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_sale` (`sale_id`),
    CONSTRAINT `fk_sale_items_sale` FOREIGN KEY (`sale_id`) REFERENCES `fks_company_store_sales` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
