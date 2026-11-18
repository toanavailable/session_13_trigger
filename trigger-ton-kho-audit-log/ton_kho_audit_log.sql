-- =====================================================
-- TỐI ƯU HÓA TOÀN VẸN DỮ LIỆU VÀ TRUY VẾT LỊCH SỬ VỚI TRIGGER
-- =====================================================

-- 0. Dữ liệu mẫu
CREATE DATABASE IF NOT EXISTS trigger_practice CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE trigger_practice;

DROP TRIGGER IF EXISTS tg_after_insert_order_item;
DROP TRIGGER IF EXISTS tg_after_update_product;
DROP TABLE IF EXISTS inventory_log;
DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS products;

CREATE TABLE products (
    product_code    VARCHAR(15)    PRIMARY KEY,
    product_name    VARCHAR(100)   NOT NULL,
    quantityInStock INT            NOT NULL DEFAULT 0,
    buyPrice        DECIMAL(10, 2) NOT NULL
);

CREATE TABLE order_items (
    order_item_id INT AUTO_INCREMENT PRIMARY KEY,
    order_id      INT            NOT NULL,
    product_code  VARCHAR(15)    NOT NULL,
    quantity      INT            NOT NULL CHECK (quantity > 0),
    price_each    DECIMAL(10, 2) NOT NULL,
    CONSTRAINT fk_item_product FOREIGN KEY (product_code) REFERENCES products (product_code)
);

INSERT INTO products (product_code, product_name, quantityInStock, buyPrice) VALUES
    ('S10_1678', '1969 Harley Davidson Ultimate Chopper', 100, 48.81),
    ('S10_1949', '1952 Alpine Renault 1300',               50, 98.58),
    ('S12_1099', '1968 Ford Mustang',                      20, 95.34);

-- =====================================================
-- BƯỚC 1: BẢNG NHẬT KÝ inventory_log
-- =====================================================
CREATE TABLE inventory_log (
    log_id       INT AUTO_INCREMENT PRIMARY KEY,
    product_code VARCHAR(15)  NOT NULL,
    old_qty      INT          NOT NULL,
    new_qty      INT          NOT NULL,
    change_date  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    note         VARCHAR(255)
);

-- =====================================================
-- BƯỚC 2: TRỪ KHO VÀ GHI LOG KHI BÁN HÀNG (AFTER INSERT)
-- =====================================================
DELIMITER //

CREATE TRIGGER tg_after_insert_order_item
AFTER INSERT ON order_items
FOR EACH ROW
BEGIN
    DECLARE v_old_qty INT DEFAULT NULL;

    -- Lấy số lượng tồn TRƯỚC khi trừ (khóa dòng để 2 đơn cùng lúc không đọc trùng)
    SELECT quantityInStock INTO v_old_qty
    FROM products
    WHERE product_code = NEW.product_code
    FOR UPDATE;

    -- Bổ sung: không cho bán vượt tồn kho (lỗi trong AFTER vẫn hủy cả lệnh INSERT)
    IF v_old_qty < NEW.quantity THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Số lượng tồn kho không đủ để bán';
    END IF;

    -- Nhiệm vụ 1: trừ kho. Bật cờ để Trigger AFTER UPDATE biết đây là bán hàng, không phải sửa tay
    SET @tg_sale_in_progress = 1;

    UPDATE products
    SET quantityInStock = quantityInStock - NEW.quantity
    WHERE product_code = NEW.product_code;

    SET @tg_sale_in_progress = 0;

    -- Nhiệm vụ 2: ghi log trước và sau khi trừ
    INSERT INTO inventory_log (product_code, old_qty, new_qty, note)
    VALUES (NEW.product_code, v_old_qty, v_old_qty - NEW.quantity, 'Bán hàng - Đơn mới');
END //

-- =====================================================
-- BƯỚC 3: THEO DÕI THAY ĐỔI THỦ CÔNG (AFTER UPDATE)
-- =====================================================
CREATE TRIGGER tg_after_update_product
AFTER UPDATE ON products
FOR EACH ROW
BEGIN
    -- Chỉ ghi khi tồn kho đổi, và lần đổi đó không do Trigger bán hàng gây ra
    IF OLD.quantityInStock <> NEW.quantityInStock
       AND COALESCE(@tg_sale_in_progress, 0) = 0 THEN
        INSERT INTO inventory_log (product_code, old_qty, new_qty, note)
        VALUES (NEW.product_code, OLD.quantityInStock, NEW.quantityInStock, 'Cập nhật kho thủ công');
    END IF;
END //

DELIMITER ;

-- =====================================================
-- BƯỚC 4: KIỂM TRA TÍNH "VÔ HÌNH" CỦA TRIGGER
-- =====================================================
-- Đơn 1001: 1 dòng hàng
INSERT INTO order_items (order_id, product_code, quantity, price_each)
VALUES (1001, 'S10_1678', 3, 95.70);

SELECT * FROM order_items;
SELECT product_code, product_name, quantityInStock FROM products;
SELECT log_id, product_code, old_qty, new_qty, note FROM inventory_log;
-- Chỉ 1 lệnh INSERT nhưng cả 3 bảng đều thay đổi:
-- order_items thêm 1 dòng, S10_1678 còn 97, inventory_log có 1 dòng 'Bán hàng - Đơn mới'

-- Đơn 1002: 2 dòng hàng trong cùng 1 lệnh INSERT -> FOR EACH ROW chạy 2 lần
INSERT INTO order_items (order_id, product_code, quantity, price_each) VALUES
    (1002, 'S10_1949', 5, 214.30),
    (1002, 'S10_1678', 2, 95.70);

-- =====================================================
-- KIỂM TRA BƯỚC 3: CẬP NHẬT KHO THỦ CÔNG
-- =====================================================
-- Nhập thêm 50 chiếc Ford Mustang -> ghi log 'Cập nhật kho thủ công'
UPDATE products SET quantityInStock = quantityInStock + 50 WHERE product_code = 'S12_1099';

-- Chỉ đổi giá nhập, tồn kho giữ nguyên -> không ghi log
UPDATE products SET buyPrice = 99.00 WHERE product_code = 'S12_1099';

SELECT product_code, product_name, quantityInStock FROM products;
SELECT log_id, product_code, old_qty, new_qty, note FROM inventory_log ORDER BY log_id;

-- [LỖI DỰ KIẾN] Bán 1000 chiếc Ford Mustang khi kho chỉ còn 70 -> bị chặn, không bảng nào thay đổi
-- Error Code: 1644. Lỗi: Số lượng tồn kho không đủ để bán
INSERT INTO order_items (order_id, product_code, quantity, price_each)
VALUES (1003, 'S12_1099', 1000, 194.57);
