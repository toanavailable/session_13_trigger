# Sự cố dời lịch khám về quá khứ

Phân tích lỗ hổng của Trigger `PreventPastAppointments` (so sánh nhầm `OLD` thay vì `NEW`) khiến lịch khám bị dời về quá khứ, và viết lại Trigger đúng logic.

## 1. Đề bài

- **Nghiệp vụ:** chức năng "Dời lịch khám" cho phép tiếp tân cập nhật `appointment_date` trong bảng `Appointments`.
- **Quy tắc hệ thống:** ngày giờ khám mới phải là thời điểm ở tương lai, tuyệt đối không được dời lịch về quá khứ.
- **Sự cố:** khi dời lịch cho `appointment_id = 104`, tiếp tân chọn nhầm tháng 1 năm ngoái. Hệ thống vẫn chấp nhận, lịch khám bị biến mất khỏi danh sách chờ của bác sĩ.
- **Mã nguồn hiện tại:**

```sql
DELIMITER //
CREATE TRIGGER PreventPastAppointments
BEFORE UPDATE ON Appointments
FOR EACH ROW
BEGIN
    -- Lỗi logic: đang lấy ngày cũ ra so sánh với hiện tại thay vì kiểm tra ngày mới
    IF OLD.appointment_date < NOW() THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Không thể đặt lịch khám vào thời điểm trong quá khứ!';
    END IF;
END //
DELIMITER ;
```

Đề bài dùng script `RikkeiClinicDB` nhưng file đó không có bảng `Appointments`, nên `doi_lich_kham_qua_khu.sql` tự tạo bảng với dữ liệu mẫu. Ngày khám được tính theo `NOW()` để script chạy vào thời điểm nào cũng cho cùng kết quả:

```sql
CREATE TABLE Appointments (
    appointment_id   INT PRIMARY KEY,
    patient_name     VARCHAR(100) NOT NULL,
    doctor_name      VARCHAR(100) NOT NULL,
    appointment_date DATETIME     NOT NULL,
    status           VARCHAR(20)  NOT NULL DEFAULT 'Pending'
);

INSERT INTO Appointments (appointment_id, patient_name, doctor_name, appointment_date, status) VALUES
    (101, 'Nguyen Van A', 'BS. Tran Minh', DATE_SUB(NOW(), INTERVAL 2 HOUR), 'Pending'),
    (102, 'Tran Thi B',   'BS. Tran Minh', DATE_ADD(NOW(), INTERVAL 3 DAY),  'Pending'),
    (103, 'Le Hoang C',   'BS. Pham Lan',  DATE_SUB(NOW(), INTERVAL 10 DAY), 'Completed'),
    (104, 'Pham Thu D',   'BS. Pham Lan',  DATE_ADD(NOW(), INTERVAL 7 DAY),  'Pending');
```

## 2. Phần A – Phân tích lỗi

### Tái hiện lỗi

```sql
UPDATE Appointments
SET appointment_date = CONCAT(YEAR(NOW()) - 1, '-01-15 09:00:00')
WHERE appointment_id = 104;
```

| appointment_id | appointment_date trước | appointment_date sau | Kết quả |
|---|---|---|---|
| 104 | NOW() + 7 ngày | 15/01 năm ngoái | **Cập nhật thành công** (lẽ ra phải bị chặn) |

### Giải thích

Trong thao tác `UPDATE`, `OLD.appointment_date` là ngày khám **đang lưu** trong bảng (ngày cũ), còn `NEW.appointment_date` là ngày **tiếp tân vừa nhập** (ngày mới). Trigger cũ chỉ kiểm tra ngày cũ: lịch 104 vốn ở tương lai nên điều kiện `OLD.appointment_date < NOW()` sai, Trigger cho qua mà không hề nhìn tới ngày mới bị nhập nhầm về quá khứ.

Mã cũ còn gây lỗi ngược lại: lịch 101 vừa diễn ra 2 tiếng trước nên `OLD.appointment_date < NOW()` đúng, và **mọi** lệnh cập nhật lịch này (kể cả chốt trạng thái `Completed`) đều bị chặn oan.

## 3. Phần B – Sửa chữa mã nguồn

```sql
DROP TRIGGER IF EXISTS PreventPastAppointments;

DELIMITER //

CREATE TRIGGER PreventPastAppointments
BEFORE UPDATE ON Appointments
FOR EACH ROW
BEGIN
    -- Chỉ kiểm tra khi ngày khám thật sự bị đổi, và kiểm tra trên giá trị MỚI
    IF NEW.appointment_date <> OLD.appointment_date
       AND NEW.appointment_date < NOW() THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Không thể đặt lịch khám vào thời điểm trong quá khứ!';
    END IF;
END //

DELIMITER ;
```

- **Kiểm tra `NEW.appointment_date`:** đây đúng là giá trị sắp được ghi vào bảng.
- **Điều kiện `NEW.appointment_date <> OLD.appointment_date`:** Trigger chỉ chặn khi ngày khám thực sự bị dời. Các cập nhật khác trên lịch đã qua (chốt `Completed`, ghi chú…) không bị chặn oan.
- **Giữ thời điểm `BEFORE`:** lỗi được ném ra trước khi dữ liệu được ghi, nên dòng sai không bao giờ vào bảng.

## 4. Kiểm thử

```sql
-- Test 1: dời lịch 104 sang tương lai
UPDATE Appointments SET appointment_date = DATE_ADD(NOW(), INTERVAL 14 DAY) WHERE appointment_id = 104;

-- Test 2: chốt trạng thái lịch 101 (đã qua giờ khám, không đổi ngày)
UPDATE Appointments SET status = 'Completed' WHERE appointment_id = 101;

-- Test 3: dời lịch 104 về tháng 1 năm ngoái
UPDATE Appointments
SET appointment_date = CONCAT(YEAR(NOW()) - 1, '-01-15 09:00:00')
WHERE appointment_id = 104;
```

| Test | Thao tác | Trigger cũ | Trigger mới |
|---|---|---|---|
| 1 | Dời 104 sang NOW() + 14 ngày | Thành công | Thành công |
| 2 | Chốt 101 thành `Completed` | **Bị chặn oan** | Thành công |
| 3 | Dời 104 về 15/01 năm ngoái | **Cho qua (lỗi)** | Bị chặn: `Error Code: 1644. Lỗi: Không thể đặt lịch khám vào thời điểm trong quá khứ!` |

Test 3 báo lỗi nên được đặt cuối file `.sql`.
