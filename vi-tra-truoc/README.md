# Tự động hóa ví trả trước

Xây dựng Trigger `AutoDeductWallet` tự động tra giá dịch vụ, kiểm tra ví và trừ tiền ngay khi bác sĩ chỉ định một dịch vụ mới (thêm dòng vào `Service_Usages`), thay cho 3 bước thủ công của y tá.

## 1. Đề bài

- **Bối cảnh:** mỗi lần bác sĩ chỉ định dịch vụ, y tá phải tự tra giá, kiểm tra số dư ví (`Wallets`) rồi trừ tiền, vừa tốn thời gian vừa dễ thất thoát.
- **Quy tắc hệ thống:** Trigger tự thực hiện tuần tự:
  1. **Tra cứu và ghi nhận:** lấy `price` từ `Services` gán vào `actual_price` của `Service_Usages`.
  2. **Thanh toán:** trừ tiền trong `Wallets` của bệnh nhân (`balance = balance - actual_price`).
- **Ràng buộc:** chặn đứng giao dịch (không thêm dịch vụ, không trừ tiền) nếu:
  - **Thẻ khóa:** ví đang `'Inactive'`, báo `"Thất bại: Ví trả trước đang bị khóa"`.
  - **Cháy ví:** số dư nhỏ hơn đơn giá, báo `"Thất bại: Số dư ví không đủ để thanh toán"`.

Script `RikkeiClinicDB` không có 3 bảng `Services`, `Wallets`, `Service_Usages`, nên file `vi_tra_truoc.sql` tự tạo:

```sql
CREATE TABLE Services (
    service_id   INT PRIMARY KEY,
    service_name VARCHAR(100)   NOT NULL,
    price        DECIMAL(12, 2) NOT NULL
);

CREATE TABLE Wallets (
    wallet_id  INT PRIMARY KEY,
    patient_id INT            NOT NULL UNIQUE,
    balance    DECIMAL(12, 2) NOT NULL DEFAULT 0,
    status     VARCHAR(20)    NOT NULL DEFAULT 'Active'
);

CREATE TABLE Service_Usages (
    usage_id     INT AUTO_INCREMENT PRIMARY KEY,
    patient_id   INT            NOT NULL,
    service_id   INT            NOT NULL,
    actual_price DECIMAL(12, 2),
    used_at      DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_usage_service FOREIGN KEY (service_id) REFERENCES Services (service_id)
);

INSERT INTO Services (service_id, service_name, price) VALUES
    (1, 'Kham tong quat', 200000),
    (2, 'Xet nghiem mau', 150000),
    (3, 'Sieu am o bung', 300000);

INSERT INTO Wallets (wallet_id, patient_id, balance, status) VALUES
    (1, 1, 1000000, 'Active'),
    (2, 2,  500000, 'Inactive'),
    (3, 3,   50000, 'Active');
```

## 2. Phần A – Phân tích kiến trúc Trigger

### Sự kiện và thời điểm: `BEFORE INSERT` trên `Service_Usages`

- **Sự kiện `INSERT`:** quy trình bắt đầu khi có một dịch vụ mới được chỉ định, tức một dòng mới được thêm vào `Service_Usages`.
- **Thời điểm `BEFORE`:**
  - Chỉ ở `BEFORE` mới gán được `SET NEW.actual_price = ...` để đơn giá đi thẳng vào dòng sắp lưu. Ở `AFTER`, `NEW` chỉ còn để đọc, và MySQL cấm `UPDATE` lại chính bảng `Service_Usages` trong Trigger.
  - Các kiểm tra thẻ khóa và cháy ví chạy trước khi dòng được ghi. Khi `SIGNAL` ném lỗi, lệnh `INSERT` bị hủy hoàn toàn, nên không có dòng dịch vụ nào được thêm và không có tiền nào bị trừ.
- **Toàn vẹn giao dịch:** với InnoDB, lệnh `INSERT` và mọi thao tác bên trong Trigger (kể cả `UPDATE Wallets`) là một khối nguyên tử. Nếu bất kỳ bước nào lỗi, cả việc trừ tiền cũng được hoàn tác.

### Biến cục bộ cần khai báo

| Biến | Kiểu | Hứng dữ liệu |
|---|---|---|
| `v_price` | DECIMAL(12,2) | Đơn giá dịch vụ, lấy từ `Services.price` |
| `v_balance` | DECIMAL(12,2) | Số dư ví hiện tại, lấy từ `Wallets.balance` |
| `v_wallet_status` | VARCHAR(20) | Trạng thái ví, lấy từ `Wallets.status` |

## 3. Phần B – Triển khai code

```sql
DROP TRIGGER IF EXISTS AutoDeductWallet;

DELIMITER //

CREATE TRIGGER AutoDeductWallet
BEFORE INSERT ON Service_Usages
FOR EACH ROW
BEGIN
    DECLARE v_price          DECIMAL(12, 2) DEFAULT NULL;
    DECLARE v_balance        DECIMAL(12, 2) DEFAULT NULL;
    DECLARE v_wallet_status  VARCHAR(20)    DEFAULT NULL;

    -- Bước 1: tra cứu đơn giá dịch vụ
    SELECT price INTO v_price
    FROM Services
    WHERE service_id = NEW.service_id;

    IF v_price IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Thất bại: Dịch vụ không tồn tại';
    END IF;

    -- Bước 2: tra cứu ví (khóa dòng ví để tránh 2 giao dịch trừ tiền cùng lúc)
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
```

- **Thứ tự kiểm tra:** khóa thẻ được xét trước số dư, nên ví vừa bị khóa vừa thiếu tiền sẽ báo "đang bị khóa", là lý do gốc.
- **Kiểm tra thêm (ngoài đề bài):** dịch vụ không tồn tại, và bệnh nhân chưa có ví. Nếu thiếu 2 kiểm tra này, `v_price` hoặc `v_balance` là `NULL` và phép so sánh `NULL < ...` không đúng, nên Trigger sẽ cho qua sai.
- **`FOR UPDATE`:** nếu 2 dịch vụ được chỉ định cùng lúc cho cùng một bệnh nhân, giao dịch thứ hai phải chờ giao dịch thứ nhất trừ tiền xong mới đọc số dư, tránh việc cả hai cùng đọc số dư cũ và trừ âm ví.

## 4. Kiểm thử

```sql
-- Kịch bản 1: giao dịch hợp lệ
INSERT INTO Service_Usages (patient_id, service_id) VALUES (1, 1);
SELECT usage_id, patient_id, service_id, actual_price FROM Service_Usages;
SELECT wallet_id, patient_id, balance, status FROM Wallets WHERE patient_id = 1;

-- Kịch bản 2: thẻ khóa
INSERT INTO Service_Usages (patient_id, service_id) VALUES (2, 1);

-- Kịch bản 3: cháy ví
INSERT INTO Service_Usages (patient_id, service_id) VALUES (3, 1);
```

| Kịch bản | Dữ liệu | Kết quả |
|---|---|---|
| 1. Hợp lệ | BN 1, ví Active 1.000.000, khám 200.000 | Thêm thành công, `actual_price = 200000`, ví còn **800.000** |
| 2. Thẻ khóa | BN 2, ví Inactive 500.000 | `Error Code: 1644. Thất bại: Ví trả trước đang bị khóa` |
| 3. Cháy ví | BN 3, ví Active 50.000, khám 200.000 | `Error Code: 1644. Thất bại: Số dư ví không đủ để thanh toán` |

Kết quả `SELECT` sau kịch bản 1:

| usage_id | patient_id | service_id | actual_price |
|---|---|---|---|
| 1 | 1 | 1 | 200000.00 |

| wallet_id | patient_id | balance | status |
|---|---|---|---|
| 1 | 1 | 800000.00 | Active |

Sau kịch bản 2 và 3, `Service_Usages` vẫn chỉ có 1 dòng, ví 2 (500.000) và ví 3 (50.000) giữ nguyên số dư. Hai kịch bản lỗi được đặt cuối file `.sql`; kịch bản 3 cần chạy riêng vì kịch bản 2 sẽ dừng script.
