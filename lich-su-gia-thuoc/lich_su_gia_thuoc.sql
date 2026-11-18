-- =====================================================
-- KIỂM SOÁT VÀ LƯU LỊCH SỬ BIẾN ĐỘNG GIÁ THUỐC
-- =====================================================

-- 0. Dữ liệu mẫu
CREATE DATABASE IF NOT EXISTS rikkei_clinic_trigger CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE rikkei_clinic_trigger;

DROP TRIGGER IF EXISTS trg_medicines_before_update_validate;
DROP TRIGGER IF EXISTS trg_medicines_after_update_log;
DROP TABLE IF EXISTS Price_Changes_Log;
DROP TABLE IF EXISTS Medicines;

CREATE TABLE Medicines (
    medicine_id    INT PRIMARY KEY,
    medicine_name  VARCHAR(100)   NOT NULL,
    price          DECIMAL(12, 2) NOT NULL,
    stock_quantity INT            NOT NULL DEFAULT 0
);

INSERT INTO Medicines (medicine_id, medicine_name, price, stock_quantity) VALUES
    (1, 'Paracetamol 500mg', 5000,  500),
    (2, 'Amoxicillin 250mg', 12000, 300),
    (3, 'Vitamin C 1000mg',  3000,  1000);

-- =====================================================
-- 1. BẢNG NHẬT KÝ Price_Changes_Log
-- =====================================================
CREATE TABLE Price_Changes_Log (
    log_id       INT AUTO_INCREMENT PRIMARY KEY,
    medicine_id  INT            NOT NULL,
    old_price    DECIMAL(12, 2) NOT NULL,
    new_price    DECIMAL(12, 2) NOT NULL,
    change_type  VARCHAR(20)    NOT NULL,                 -- 'TĂNG GIÁ' / 'GIẢM GIÁ'
    price_diff   DECIMAL(12, 2) NOT NULL,                 -- luôn là số dương
    changed_by   VARCHAR(100),                            -- tài khoản thực hiện
    changed_at   DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_log_change_type CHECK (change_type IN ('TĂNG GIÁ', 'GIẢM GIÁ')),
    CONSTRAINT chk_log_price_diff  CHECK (price_diff > 0),
    CONSTRAINT fk_log_medicine FOREIGN KEY (medicine_id) REFERENCES Medicines (medicine_id)
);

-- =====================================================
-- 2. TRIGGER RÀO CHẮN (BEFORE UPDATE): chặn giá mới <= 0
-- =====================================================
DELIMITER //

CREATE TRIGGER trg_medicines_before_update_validate
BEFORE UPDATE ON Medicines
FOR EACH ROW
BEGIN
    IF NEW.price <> OLD.price AND NEW.price <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Giá thuốc mới không hợp lệ';
    END IF;
END //

-- =====================================================
-- 3. TRIGGER GHI LOG (AFTER UPDATE): chỉ ghi khi giá thật sự thay đổi
-- =====================================================
CREATE TRIGGER trg_medicines_after_update_log
AFTER UPDATE ON Medicines
FOR EACH ROW
BEGIN
    IF NEW.price > OLD.price THEN
        INSERT INTO Price_Changes_Log (medicine_id, old_price, new_price, change_type, price_diff, changed_by)
        VALUES (NEW.medicine_id, OLD.price, NEW.price, 'TĂNG GIÁ', NEW.price - OLD.price, USER());
    ELSEIF NEW.price < OLD.price THEN
        INSERT INTO Price_Changes_Log (medicine_id, old_price, new_price, change_type, price_diff, changed_by)
        VALUES (NEW.medicine_id, OLD.price, NEW.price, 'GIẢM GIÁ', OLD.price - NEW.price, USER());
    END IF;
    -- Giá không đổi (sửa tên, cập nhật tồn kho...) -> không làm gì, không sinh log rác
END //

DELIMITER ;

-- =====================================================
-- 4. KIỂM THỬ
-- =====================================================
-- Test 1: tăng giá hợp lệ Paracetamol 5.000 -> 6.500
UPDATE Medicines SET price = 6500 WHERE medicine_id = 1;

-- Test 2: giảm giá hợp lệ Amoxicillin 12.000 -> 10.000
UPDATE Medicines SET price = 10000 WHERE medicine_id = 2;

-- Test 3: cập nhật tồn kho Vitamin C, giá không đổi -> không sinh log
UPDATE Medicines SET stock_quantity = stock_quantity + 200 WHERE medicine_id = 3;

SELECT medicine_id, medicine_name, price, stock_quantity FROM Medicines;

SELECT log_id, medicine_id, old_price, new_price, change_type, price_diff
FROM Price_Changes_Log
ORDER BY log_id;

-- Test 4 [LỖI DỰ KIẾN]: gõ nhầm giá âm -> bị chặn, không ghi log
-- Error Code: 1644. Lỗi: Giá thuốc mới không hợp lệ
UPDATE Medicines SET price = -5000 WHERE medicine_id = 3;
