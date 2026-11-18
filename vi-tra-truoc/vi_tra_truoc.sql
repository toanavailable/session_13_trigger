-- =====================================================
-- TỰ ĐỘNG HÓA VÍ TRẢ TRƯỚC - Trigger AutoDeductWallet
-- =====================================================

-- 0. Dữ liệu mẫu
CREATE DATABASE IF NOT EXISTS rikkei_clinic_trigger CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE rikkei_clinic_trigger;

DROP TRIGGER IF EXISTS AutoDeductWallet;
DROP TABLE IF EXISTS Service_Usages;
DROP TABLE IF EXISTS Wallets;
DROP TABLE IF EXISTS Services;

CREATE TABLE Services (
    service_id   INT PRIMARY KEY,
    service_name VARCHAR(100)   NOT NULL,
    price        DECIMAL(12, 2) NOT NULL
);

CREATE TABLE Wallets (
    wallet_id  INT PRIMARY KEY,
    patient_id INT            NOT NULL UNIQUE,
    balance    DECIMAL(12, 2) NOT NULL DEFAULT 0,
    status     VARCHAR(20)    NOT NULL DEFAULT 'Active'   -- Active / Inactive
);

CREATE TABLE Service_Usages (
    usage_id     INT AUTO_INCREMENT PRIMARY KEY,
    patient_id   INT            NOT NULL,
    service_id   INT            NOT NULL,
    actual_price DECIMAL(12, 2),                          -- Trigger tự điền
    used_at      DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_usage_service FOREIGN KEY (service_id) REFERENCES Services (service_id)
);

INSERT INTO Services (service_id, service_name, price) VALUES
    (1, 'Kham tong quat',   200000),
    (2, 'Xet nghiem mau',   150000),
    (3, 'Sieu am o bung',   300000);

INSERT INTO Wallets (wallet_id, patient_id, balance, status) VALUES
    (1, 1, 1000000, 'Active'),     -- ví hợp lệ
    (2, 2,  500000, 'Inactive'),   -- thẻ khóa
    (3, 3,   50000, 'Active');     -- cháy ví

-- =====================================================
-- 1. TRIGGER AutoDeductWallet
-- =====================================================
DROP TRIGGER IF EXISTS AutoDeductWallet;

DELIMITER //

CREATE TRIGGER AutoDeductWallet
BEFORE INSERT ON Service_Usages
FOR EACH ROW
BEGIN
    DECLARE v_price          DECIMAL(12, 2) DEFAULT NULL;   -- đơn giá dịch vụ
    DECLARE v_balance        DECIMAL(12, 2) DEFAULT NULL;   -- số dư ví
    DECLARE v_wallet_status  VARCHAR(20)    DEFAULT NULL;   -- trạng thái ví

    -- Bước 1: tra cứu đơn giá dịch vụ
    SELECT price INTO v_price
    FROM Services
    WHERE service_id = NEW.service_id;

    IF v_price IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Thất bại: Dịch vụ không tồn tại';
    END IF;

    -- Bước 2: tra cứu ví của bệnh nhân (khóa dòng ví để tránh 2 giao dịch trừ tiền cùng lúc)
    SELECT balance, status INTO v_balance, v_wallet_status
    FROM Wallets
    WHERE patient_id = NEW.patient_id
    FOR UPDATE;

    IF v_wallet_status IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Thất bại: Bệnh nhân chưa có ví trả trước';
    END IF;

    -- Bước 3: kiểm tra ràng buộc
    IF v_wallet_status = 'Inactive' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Thất bại: Ví trả trước đang bị khóa';
    END IF;

    IF v_balance < v_price THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Thất bại: Số dư ví không đủ để thanh toán';
    END IF;

    -- Bước 4: ghi nhận đơn giá thực tế vào dòng sắp chèn
    SET NEW.actual_price = v_price;

    -- Bước 5: trừ tiền trong ví
    UPDATE Wallets
    SET balance = balance - v_price
    WHERE patient_id = NEW.patient_id;
END //

DELIMITER ;

-- =====================================================
-- 2. KIỂM THỬ
-- =====================================================
-- Kịch bản 1: giao dịch hợp lệ (bệnh nhân 1, ví Active 1.000.000, khám tổng quát 200.000)
INSERT INTO Service_Usages (patient_id, service_id) VALUES (1, 1);

SELECT usage_id, patient_id, service_id, actual_price FROM Service_Usages;
SELECT wallet_id, patient_id, balance, status FROM Wallets WHERE patient_id = 1;
-- Kết quả: actual_price = 200000, balance còn 800000

-- Kịch bản 2 [LỖI DỰ KIẾN]: thẻ khóa (bệnh nhân 2 có ví Inactive)
-- Error Code: 1644. Thất bại: Ví trả trước đang bị khóa
INSERT INTO Service_Usages (patient_id, service_id) VALUES (2, 1);

-- Kịch bản 3 [LỖI DỰ KIẾN]: cháy ví (bệnh nhân 3 còn 50.000, khám 200.000)
-- Error Code: 1644. Thất bại: Số dư ví không đủ để thanh toán
INSERT INTO Service_Usages (patient_id, service_id) VALUES (3, 1);

-- Sau 2 kịch bản lỗi: Service_Usages vẫn chỉ có 1 dòng, ví 2 và ví 3 giữ nguyên số dư
-- SELECT * FROM Service_Usages;
-- SELECT * FROM Wallets;
