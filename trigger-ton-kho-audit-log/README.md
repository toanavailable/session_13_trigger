# Tối ưu hóa toàn vẹn dữ liệu và truy vết lịch sử với Trigger

Xây dựng hệ thống tự động trừ kho khi bán hàng và ghi nhật ký (Audit Log) mọi biến động tồn kho cho bảng `products` và `order_items`.

## 1. Đề bài

- **Mục tiêu:**
  - dùng Trigger để duy trì toàn vẹn dữ liệu tự động giữa bảng bán hàng và bảng kho;
  - ghi nhật ký thay đổi (Audit Log) để theo dõi vết dữ liệu;
  - dùng đúng `OLD` và `NEW` trong từng tình huống.
- **Yêu cầu:**
  - **Bước 1:** tạo bảng `inventory_log` gồm `log_id`, `product_code`, `old_qty`, `new_qty`, `change_date`, `note`.
  - **Bước 2:** Trigger `tg_after_insert_order_item` (AFTER INSERT trên `order_items`):
    - tự trừ `quantityInStock` của `products` theo `NEW.quantity`;
    - ghi log số lượng trước và sau khi trừ, ghi chú `"Bán hàng - Đơn mới"`.
  - **Bước 3:** Trigger `tg_after_update_product` (AFTER UPDATE trên `products`): nếu `quantityInStock` thay đổi, ghi `OLD` và `NEW` vào log với ghi chú `"Cập nhật kho thủ công"`.
  - **Bước 4:** chèn một bản ghi vào `order_items`, `SELECT` cả 3 bảng và giải thích vì sao 1 lệnh `INSERT` làm cả 3 bảng thay đổi.
  - **Bước 5:** đánh giá nhược điểm khi có 10.000 đơn hàng mỗi giây.

## 2. Bước 1 – Cấu trúc bảng

```sql
CREATE DATABASE IF NOT EXISTS trigger_practice CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE trigger_practice;

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

CREATE TABLE inventory_log (
    log_id       INT AUTO_INCREMENT PRIMARY KEY,
    product_code VARCHAR(15)  NOT NULL,
    old_qty      INT          NOT NULL,
    new_qty      INT          NOT NULL,
    change_date  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    note         VARCHAR(255)
);

INSERT INTO products (product_code, product_name, quantityInStock, buyPrice) VALUES
    ('S10_1678', '1969 Harley Davidson Ultimate Chopper', 100, 48.81),
    ('S10_1949', '1952 Alpine Renault 1300',               50, 98.58),
    ('S12_1099', '1968 Ford Mustang',                      20, 95.34);
```

## 3. Bước 2 – Trigger trừ kho và ghi log khi bán hàng

```sql
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

    -- Bổ sung: không cho bán vượt tồn kho
    IF v_old_qty < NEW.quantity THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Số lượng tồn kho không đủ để bán';
    END IF;

    -- Nhiệm vụ 1: trừ kho (bật cờ để Trigger AFTER UPDATE biết đây là bán hàng)
    SET @tg_sale_in_progress = 1;

    UPDATE products
    SET quantityInStock = quantityInStock - NEW.quantity
    WHERE product_code = NEW.product_code;

    SET @tg_sale_in_progress = 0;

    -- Nhiệm vụ 2: ghi log trước và sau khi trừ
    INSERT INTO inventory_log (product_code, old_qty, new_qty, note)
    VALUES (NEW.product_code, v_old_qty, v_old_qty - NEW.quantity, 'Bán hàng - Đơn mới');
END //

DELIMITER ;
```

- **`NEW.quantity`:** với sự kiện `INSERT` chỉ có biến `NEW`, chứa số lượng của dòng hàng vừa bán.
- **`v_old_qty`:** số lượng trước khi trừ phải được đọc từ `products` **trước** lệnh `UPDATE`; số lượng sau khi trừ là `v_old_qty - NEW.quantity`.
- **Kiểm tra tồn kho (ngoài đề bài):** chặn bán vượt số lượng đang có. `SIGNAL` trong Trigger `AFTER` vẫn hủy cả lệnh `INSERT` ban đầu, vì với InnoDB lệnh gốc và Trigger là một khối nguyên tử.

## 4. Bước 3 – Trigger theo dõi cập nhật kho thủ công

```sql
DELIMITER //

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
```

- **`OLD` và `NEW`:** sự kiện `UPDATE` có cả hai biến: `OLD.quantityInStock` là số lượng trước khi sửa, `NEW.quantityInStock` là số lượng sau khi sửa.
- **Điều kiện `OLD.quantityInStock <> NEW.quantityInStock`:** chỉ ghi log khi tồn kho thật sự đổi; sửa giá hay tên sản phẩm không sinh log.
- **Biến cờ `@tg_sale_in_progress`:** lệnh `UPDATE products` bên trong Trigger bán hàng cũng kích hoạt Trigger này. Không có cờ, mỗi lần bán hàng sẽ sinh **2 dòng log** cho cùng một thay đổi, một trong số đó ghi sai là "Cập nhật kho thủ công". Trigger bán hàng bật cờ trước khi trừ kho và tắt ngay sau đó, nên Trigger này bỏ qua đúng lần cập nhật do bán hàng gây ra.

## 5. Bước 4 – Kiểm tra tính "vô hình" của Trigger

```sql
INSERT INTO order_items (order_id, product_code, quantity, price_each)
VALUES (1001, 'S10_1678', 3, 95.70);

SELECT * FROM order_items;
SELECT product_code, product_name, quantityInStock FROM products;
SELECT log_id, product_code, old_qty, new_qty, note FROM inventory_log;
```

| Bảng | Thay đổi |
|---|---|
| `order_items` | Thêm 1 dòng: đơn 1001, `S10_1678`, số lượng 3 |
| `products` | `S10_1678`: `quantityInStock` từ 100 còn **97** |
| `inventory_log` | Thêm 1 dòng: `S10_1678`, 100 → 97, `Bán hàng - Đơn mới` |

**Vì sao 1 lệnh INSERT làm cả 3 bảng thay đổi?** Lệnh `INSERT` vào `order_items` kích hoạt ngầm Trigger `tg_after_insert_order_item`. Trigger này chạy tiếp lệnh `UPDATE products` (trừ kho) và lệnh `INSERT inventory_log` (ghi log), nên người gõ lệnh chỉ thấy 1 câu `INSERT` nhưng Database đã tự làm thêm 2 thao tác ghi trên 2 bảng khác. Cả 3 thao tác nằm trong cùng một giao dịch: nếu một bước lỗi thì tất cả được hoàn tác.

### Các kiểm thử thêm

```sql
-- Đơn 1002: 2 dòng hàng trong cùng 1 lệnh INSERT -> FOR EACH ROW chạy 2 lần
INSERT INTO order_items (order_id, product_code, quantity, price_each) VALUES
    (1002, 'S10_1949', 5, 214.30),
    (1002, 'S10_1678', 2, 95.70);

-- Nhập thêm 50 chiếc Ford Mustang
UPDATE products SET quantityInStock = quantityInStock + 50 WHERE product_code = 'S12_1099';

-- Chỉ đổi giá nhập, tồn kho giữ nguyên
UPDATE products SET buyPrice = 99.00 WHERE product_code = 'S12_1099';

-- Bán 1000 chiếc Ford Mustang khi kho chỉ còn 70
INSERT INTO order_items (order_id, product_code, quantity, price_each)
VALUES (1003, 'S12_1099', 1000, 194.57);
```

| Thao tác | Kết quả |
|---|---|
| Đơn 1002 có 2 dòng hàng | 2 dòng log `Bán hàng - Đơn mới`: `S10_1949` 50 → 45, `S10_1678` 97 → 95 |
| Nhập thêm 50 `S12_1099` | 1 dòng log `Cập nhật kho thủ công`: 20 → 70 |
| Chỉ đổi `buyPrice` | Không sinh log |
| Bán 1000 `S12_1099` | `Error Code: 1644. Lỗi: Số lượng tồn kho không đủ để bán`, cả 3 bảng không thay đổi |

Bảng `inventory_log` cuối cùng:

| log_id | product_code | old_qty | new_qty | note |
|---|---|---|---|---|
| 1 | S10_1678 | 100 | 97 | Bán hàng - Đơn mới |
| 2 | S10_1949 | 50 | 45 | Bán hàng - Đơn mới |
| 3 | S10_1678 | 97 | 95 | Bán hàng - Đơn mới |
| 4 | S12_1099 | 20 | 70 | Cập nhật kho thủ công |

Lệnh bán vượt tồn kho báo lỗi nên được đặt cuối file `.sql`.

## 6. Bước 5 – Đánh giá nhược điểm khi có 10.000 đơn hàng mỗi giây

- **Khối lượng ghi tăng gấp 3:** mỗi lệnh `INSERT` vào `order_items` kéo theo thêm 1 `UPDATE products` và 1 `INSERT inventory_log`. 10.000 đơn/giây thành khoảng 30.000 thao tác ghi/giây, cùng lượng log giao dịch (redo log, binlog) tương ứng. Bảng `inventory_log` cũng phình rất nhanh.
- **Tranh chấp khóa trên sản phẩm "hot":** lệnh `UPDATE` (và `FOR UPDATE`) khóa dòng sản phẩm cho tới khi giao dịch kết thúc. Khi hàng nghìn đơn cùng mua một mặt hàng, các giao dịch phải xếp hàng chờ khóa của cùng một dòng, gây nghẽn, timeout và có thể deadlock.
- **Giao dịch dài hơn:** người gọi phải chờ cả Trigger chạy xong mới nhận được kết quả, nên độ trễ mỗi đơn tăng và thông lượng của MySQL Server giảm.
- **Khó theo dõi và tối ưu:** Trigger chạy ngầm, không hiện trong câu lệnh của ứng dụng, nên khi hệ thống chậm rất khó nhận ra nguyên nhân nằm ở Trigger.

**Hướng xử lý:**
- Gom và xử lý trừ kho theo lô từ tầng ứng dụng hoặc qua hàng đợi (message queue).
- Ghi log bất đồng bộ.
- Hoặc chuyển logic vào Stored Procedure gọi chủ động, để kiểm soát giao dịch rõ ràng hơn.
