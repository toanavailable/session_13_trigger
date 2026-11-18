# Kiểm soát và lưu lịch sử biến động giá thuốc

Xây dựng module tự động: chặn giá thuốc không hợp lệ (âm hoặc bằng 0) và ghi một bản ghi lịch sử vào `Price_Changes_Log` mỗi khi giá trong bảng `Medicines` tăng hoặc giảm.

## 1. Đề bài

- **Bối cảnh:** phòng khám thường xuyên điều chỉnh giá bán thuốc nhưng chưa có kiểm soát. Giám đốc yêu cầu mỗi lần giá thuốc bị cập nhật, hệ thống tự tính chênh lệch và ghi lịch sử để kiểm toán nội bộ.
- **Quy tắc nghiệp vụ:**
  - Giá mới > giá cũ: ghi `'TĂNG GIÁ'`, chênh lệch = giá mới − giá cũ.
  - Giá mới < giá cũ: ghi `'GIẢM GIÁ'`, chênh lệch = giá cũ − giá mới.
  - Log bắt buộc có: mã thuốc, giá cũ, giá mới, trạng thái (tăng/giảm), số tiền chênh lệch.
- **Vấn đề cần xử lý:**
  - Cập nhật thông tin khác (sửa tên, cập nhật tồn kho) mà giá không đổi thì **không** được sinh log.
  - Giá mới là số âm hoặc bằng 0 (VD `-5000`) thì phải **chặn** giao dịch và báo lỗi `"Lỗi: Giá thuốc mới không hợp lệ"`.

Bảng `Medicines` và dữ liệu mẫu được tạo trong `lich_su_gia_thuoc.sql`:

```sql
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
```

## 2. Phân tích và giải pháp

### Cấu trúc bảng `Price_Changes_Log`

| Cột | Kiểu | Ý nghĩa |
|---|---|---|
| `log_id` | INT, AUTO_INCREMENT, PK | Mã bản ghi lịch sử |
| `medicine_id` | INT, FK → `Medicines` | Mã thuốc bị đổi giá |
| `old_price` | DECIMAL(12,2) | Giá cũ (`OLD.price`) |
| `new_price` | DECIMAL(12,2) | Giá mới (`NEW.price`) |
| `change_type` | VARCHAR(20), CHECK | `'TĂNG GIÁ'` hoặc `'GIẢM GIÁ'` |
| `price_diff` | DECIMAL(12,2), CHECK > 0 | Số tiền chênh lệch, luôn dương |
| `changed_by` | VARCHAR(100) | Tài khoản thực hiện (`USER()`), phục vụ kiểm toán |
| `changed_at` | DATETIME, mặc định `CURRENT_TIMESTAMP` | Thời điểm thay đổi |

### Thời điểm kích hoạt

Giải pháp tách thành **2 Trigger** trên sự kiện `UPDATE` của bảng `Medicines`:

| Trigger | Thời điểm | Nhiệm vụ | Lý do |
|---|---|---|---|
| `trg_medicines_before_update_validate` | `BEFORE UPDATE` | Chặn giá mới ≤ 0 | Lỗi được ném ra **trước** khi dữ liệu sai được ghi vào bảng |
| `trg_medicines_after_update_log` | `AFTER UPDATE` | Ghi lịch sử giá | Chỉ ghi log khi lệnh cập nhật **đã thành công**, nên log phản ánh đúng thay đổi thật |

### Luồng xử lý OLD/NEW

| Trường hợp | Điều kiện | Xử lý |
|---|---|---|
| Giá mới không hợp lệ | `NEW.price <> OLD.price AND NEW.price <= 0` | `SIGNAL SQLSTATE '45000'`, hủy cả lệnh UPDATE, không có log |
| Tăng giá | `NEW.price > OLD.price` | Ghi `'TĂNG GIÁ'`, `price_diff = NEW.price - OLD.price` |
| Giảm giá | `NEW.price < OLD.price` | Ghi `'GIẢM GIÁ'`, `price_diff = OLD.price - NEW.price` |
| Giá không đổi | `NEW.price = OLD.price` | Không làm gì, không sinh log rác |

Điều kiện `NEW.price <> OLD.price` ở Trigger rào chắn giúp thuốc nào lỡ có giá cũ bằng 0 vẫn cập nhật được tồn kho bình thường; chỉ khi **nhập giá mới** thì giá đó mới bị kiểm tra.

## 3. Triển khai

```sql
CREATE TABLE Price_Changes_Log (
    log_id       INT AUTO_INCREMENT PRIMARY KEY,
    medicine_id  INT            NOT NULL,
    old_price    DECIMAL(12, 2) NOT NULL,
    new_price    DECIMAL(12, 2) NOT NULL,
    change_type  VARCHAR(20)    NOT NULL,
    price_diff   DECIMAL(12, 2) NOT NULL,
    changed_by   VARCHAR(100),
    changed_at   DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_log_change_type CHECK (change_type IN ('TĂNG GIÁ', 'GIẢM GIÁ')),
    CONSTRAINT chk_log_price_diff  CHECK (price_diff > 0),
    CONSTRAINT fk_log_medicine FOREIGN KEY (medicine_id) REFERENCES Medicines (medicine_id)
);

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
END //

DELIMITER ;
```

## 4. Kiểm thử

```sql
UPDATE Medicines SET price = 6500  WHERE medicine_id = 1;                       -- Test 1: tăng giá
UPDATE Medicines SET price = 10000 WHERE medicine_id = 2;                       -- Test 2: giảm giá
UPDATE Medicines SET stock_quantity = stock_quantity + 200 WHERE medicine_id = 3; -- Test 3: chỉ đổi tồn kho
UPDATE Medicines SET price = -5000 WHERE medicine_id = 3;                       -- Test 4: giá âm
```

| Test | Trường hợp | Kết quả mong đợi |
|---|---|---|
| 1 | Tăng giá hợp lệ 5.000 → 6.500 | Cập nhật thành công, sinh 1 log `TĂNG GIÁ`, chênh lệch 1.500 |
| 2 | Giảm giá hợp lệ 12.000 → 10.000 | Cập nhật thành công, sinh 1 log `GIẢM GIÁ`, chênh lệch 2.000 |
| 3 | Cập nhật tồn kho, giá giữ nguyên | Tồn kho Vitamin C thành 1.200, **không** sinh log |
| 4 | Giá mới −5.000 | Bị chặn: `Error Code: 1644. Lỗi: Giá thuốc mới không hợp lệ`, giá vẫn là 3.000, không sinh log |

Bảng `Price_Changes_Log` sau 4 test:

| log_id | medicine_id | old_price | new_price | change_type | price_diff |
|---|---|---|---|---|---|
| 1 | 1 | 5000.00 | 6500.00 | TĂNG GIÁ | 1500.00 |
| 2 | 2 | 12000.00 | 10000.00 | GIẢM GIÁ | 2000.00 |

Test 4 báo lỗi nên được đặt cuối file `.sql`.
