from fastapi import FastAPI, HTTPException, Depends
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import create_engine, Column, Integer, String, Float, Date, DateTime, Boolean
from sqlalchemy.orm import declarative_base, sessionmaker, Session
from pydantic import BaseModel
from typing import Optional, List
from datetime import date, datetime, timedelta
from dateutil.relativedelta import relativedelta
from apscheduler.schedulers.background import BackgroundScheduler
import logging

# ─── DB ───────────────────────────────────────────────────────────────────────
DATABASE_URL = "sqlite:///./subscriptions.db"
engine = create_engine(DATABASE_URL, connect_args={"check_same_thread": False})
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

# ─── MODEL ────────────────────────────────────────────────────────────────────
class Subscription(Base):
    __tablename__ = "subscriptions"

    id          = Column(Integer, primary_key=True, index=True)
    name        = Column(String, nullable=False)          # Название: "Netflix"
    category    = Column(String, nullable=False)          # streaming / software / delivery / storage / other
    price       = Column(Float, nullable=False)           # Стоимость в рублях
    currency    = Column(String, default="RUB")
    period      = Column(String, nullable=False)          # monthly / yearly / weekly
    next_payment = Column(Date, nullable=False)           # Дата следующего списания
    description = Column(String, nullable=True)
    is_active   = Column(Boolean, default=True)
    created_at  = Column(DateTime, default=datetime.utcnow)

    # Уведомление: было ли уже отправлено для текущего цикла
    notified    = Column(Boolean, default=False)

Base.metadata.create_all(bind=engine)

# ─── SCHEMAS ──────────────────────────────────────────────────────────────────
class SubscriptionCreate(BaseModel):
    name: str
    category: str
    price: float
    currency: str = "RUB"
    period: str                   # monthly / yearly / weekly
    next_payment: date
    description: Optional[str] = None
    is_active: bool = True

class SubscriptionUpdate(BaseModel):
    name: Optional[str] = None
    category: Optional[str] = None
    price: Optional[float] = None
    currency: Optional[str] = None
    period: Optional[str] = None
    next_payment: Optional[date] = None
    description: Optional[str] = None
    is_active: Optional[bool] = None

class SubscriptionOut(BaseModel):
    id: int
    name: str
    category: str
    price: float
    currency: str
    period: str
    next_payment: date
    description: Optional[str]
    is_active: bool
    created_at: datetime
    days_until_payment: int       # удобное поле для фронта

    class Config:
        from_attributes = True

# ─── HELPERS ──────────────────────────────────────────────────────────────────
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

def days_until(d: date) -> int:
    return (d - date.today()).days

def monthly_price(sub: Subscription) -> float:
    """Приводим цену к месячной для аналитики"""
    if sub.period == "monthly":
        return sub.price
    elif sub.period == "yearly":
        return sub.price / 12
    elif sub.period == "weekly":
        return sub.price * 4.33
    return sub.price

def next_payment_after(current: date, period: str) -> date:
    if period == "monthly":
        return current + relativedelta(months=1)
    elif period == "yearly":
        return current + relativedelta(years=1)
    elif period == "weekly":
        return current + timedelta(weeks=1)
    return current + relativedelta(months=1)

def enrich(sub: Subscription) -> dict:
    d = sub.__dict__.copy()
    d["days_until_payment"] = days_until(sub.next_payment)
    return d

# ─── APP ──────────────────────────────────────────────────────────────────────
app = FastAPI(
    title="Subscription Monitor API",
    description="MVP REST API для управления подписками",
    version="1.0.0"
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ─── SUBSCRIPTIONS CRUD ───────────────────────────────────────────────────────
@app.get("/subscriptions", response_model=List[SubscriptionOut], tags=["Subscriptions"])
def list_subscriptions(
    active_only: bool = False,
    category: Optional[str] = None,
    db: Session = Depends(get_db)
):
    """Получить все подписки. Фильтры: active_only, category"""
    q = db.query(Subscription)
    if active_only:
        q = q.filter(Subscription.is_active == True)
    if category:
        q = q.filter(Subscription.category == category)
    return [enrich(s) for s in q.all()]


@app.post("/subscriptions", response_model=SubscriptionOut, status_code=201, tags=["Subscriptions"])
def create_subscription(data: SubscriptionCreate, db: Session = Depends(get_db)):
    """Добавить подписку вручную"""
    sub = Subscription(**data.model_dump())
    db.add(sub)
    db.commit()
    db.refresh(sub)
    return enrich(sub)


@app.get("/subscriptions/{sub_id}", response_model=SubscriptionOut, tags=["Subscriptions"])
def get_subscription(sub_id: int, db: Session = Depends(get_db)):
    sub = db.query(Subscription).filter(Subscription.id == sub_id).first()
    if not sub:
        raise HTTPException(status_code=404, detail="Subscription not found")
    return enrich(sub)


@app.put("/subscriptions/{sub_id}", response_model=SubscriptionOut, tags=["Subscriptions"])
def update_subscription(sub_id: int, data: SubscriptionUpdate, db: Session = Depends(get_db)):
    """Редактировать подписку"""
    sub = db.query(Subscription).filter(Subscription.id == sub_id).first()
    if not sub:
        raise HTTPException(status_code=404, detail="Subscription not found")
    for field, value in data.model_dump(exclude_unset=True).items():
        setattr(sub, field, value)
    db.commit()
    db.refresh(sub)
    return enrich(sub)


@app.delete("/subscriptions/{sub_id}", tags=["Subscriptions"])
def delete_subscription(sub_id: int, db: Session = Depends(get_db)):
    sub = db.query(Subscription).filter(Subscription.id == sub_id).first()
    if not sub:
        raise HTTPException(status_code=404, detail="Subscription not found")
    db.delete(sub)
    db.commit()
    return {"detail": "Deleted"}


@app.post("/subscriptions/{sub_id}/pause", response_model=SubscriptionOut, tags=["Subscriptions"])
def pause_subscription(sub_id: int, db: Session = Depends(get_db)):
    """Приостановить подписку (is_active = False)"""
    sub = db.query(Subscription).filter(Subscription.id == sub_id).first()
    if not sub:
        raise HTTPException(status_code=404, detail="Subscription not found")
    sub.is_active = False
    db.commit()
    db.refresh(sub)
    return enrich(sub)


# ─── ANALYTICS ────────────────────────────────────────────────────────────────
@app.get("/analytics/summary", tags=["Analytics"])
def analytics_summary(db: Session = Depends(get_db)):
    """
    Сводка расходов:
    - total_monthly  — суммарные расходы в месяц
    - total_yearly   — суммарные расходы в год
    - by_category    — разбивка по категориям (месячная стоимость)
    - by_period      — количество подписок по периоду списания
    """
    subs = db.query(Subscription).filter(Subscription.is_active == True).all()

    by_category: dict = {}
    by_period: dict = {}
    total_monthly = 0.0

    for s in subs:
        mp = monthly_price(s)
        total_monthly += mp
        by_category[s.category] = round(by_category.get(s.category, 0) + mp, 2)
        by_period[s.period] = by_period.get(s.period, 0) + 1

    return {
        "total_monthly": round(total_monthly, 2),
        "total_yearly": round(total_monthly * 12, 2),
        "by_category": by_category,
        "by_period": by_period,
        "active_count": len(subs),
    }


@app.get("/analytics/forecast", tags=["Analytics"])
def analytics_forecast(db: Session = Depends(get_db)):
    """
    Прогноз списаний:
    - next_30_days   — ближайшие 30 дней (список платежей с датами)
    - monthly_totals — сумма по каждому из следующих 12 месяцев
    """
    subs = db.query(Subscription).filter(Subscription.is_active == True).all()
    today = date.today()

    # Ближайшие 30 дней
    upcoming = []
    for s in subs:
        d = s.next_payment
        if today <= d <= today + timedelta(days=30):
            upcoming.append({
                "id": s.id,
                "name": s.name,
                "price": s.price,
                "currency": s.currency,
                "date": d.isoformat(),
                "days_left": days_until(d),
            })
    upcoming.sort(key=lambda x: x["date"])

    # Помесячный прогноз на 12 месяцев
    monthly_totals = []
    for i in range(12):
        month_start = (today.replace(day=1) + relativedelta(months=i))
        month_end   = month_start + relativedelta(months=1) - timedelta(days=1)
        label = month_start.strftime("%Y-%m")
        total = 0.0
        for s in subs:
            # Симулируем все даты списания этой подписки в данном месяце
            d = s.next_payment
            # Откатываемся назад до начала истории, потом идём вперёд
            while d > month_start:
                d = next_payment_after.__wrapped__(d, s.period) if hasattr(next_payment_after, '__wrapped__') else d - relativedelta(months=1) if s.period == "monthly" else d - relativedelta(years=1) if s.period == "yearly" else d - timedelta(weeks=1)
            while d <= month_end:
                if d >= month_start:
                    total += s.price
                d = next_payment_after(d, s.period)
        monthly_totals.append({"month": label, "total": round(total, 2)})

    return {
        "next_30_days": upcoming,
        "monthly_totals": monthly_totals,
    }


@app.get("/analytics/history", tags=["Analytics"])
def analytics_history(
    from_date: Optional[date] = None,
    to_date: Optional[date] = None,
    db: Session = Depends(get_db)
):
    """Расходы за период (для графиков). По умолчанию — последние 6 месяцев."""
    today = date.today()
    if not from_date:
        from_date = today - relativedelta(months=6)
    if not to_date:
        to_date = today

    subs = db.query(Subscription).all()

    # Строим помесячную сводку за запрошенный период
    result = []
    cursor = from_date.replace(day=1)
    while cursor <= to_date:
        month_end = cursor + relativedelta(months=1) - timedelta(days=1)
        total = 0.0
        breakdown = {}
        for s in subs:
            # Считаем все реальные списания в этом месяце
            d = s.next_payment
            while d > cursor:
                d = d - relativedelta(months=1) if s.period == "monthly" \
                    else d - relativedelta(years=1) if s.period == "yearly" \
                    else d - timedelta(weeks=1)
            while d <= month_end:
                if d >= cursor:
                    total += s.price
                    breakdown[s.category] = round(breakdown.get(s.category, 0) + s.price, 2)
                d = next_payment_after(d, s.period)
        result.append({
            "month": cursor.strftime("%Y-%m"),
            "total": round(total, 2),
            "breakdown": breakdown,
        })
        cursor += relativedelta(months=1)

    return result


# ─── NOTIFICATIONS ────────────────────────────────────────────────────────────
@app.get("/notifications", tags=["Notifications"])
def get_notifications(days_ahead: int = 3, db: Session = Depends(get_db)):
    """
    Подписки, у которых списание через days_ahead дней (по умолчанию 3).
    Используй для показа алертов в интерфейсе.
    """
    today = date.today()
    deadline = today + timedelta(days=days_ahead)
    subs = db.query(Subscription).filter(
        Subscription.is_active == True,
        Subscription.next_payment >= today,
        Subscription.next_payment <= deadline,
    ).all()

    return [
        {
            "id": s.id,
            "name": s.name,
            "price": s.price,
            "currency": s.currency,
            "next_payment": s.next_payment.isoformat(),
            "days_left": days_until(s.next_payment),
        }
        for s in subs
    ]


# ─── BACKGROUND: advance next_payment after due date ─────────────────────────
def advance_payments():
    """Каждый день в полночь: если дата списания прошла — перекидываем на следующий цикл"""
    db = SessionLocal()
    try:
        today = date.today()
        overdue = db.query(Subscription).filter(
            Subscription.is_active == True,
            Subscription.next_payment < today,
        ).all()
        for s in overdue:
            while s.next_payment < today:
                s.next_payment = next_payment_after(s.next_payment, s.period)
            s.notified = False  # сбрасываем флаг уведомления для нового цикла
        db.commit()
        logging.info(f"[scheduler] Advanced {len(overdue)} subscriptions")
    finally:
        db.close()

scheduler = BackgroundScheduler()
scheduler.add_job(advance_payments, "cron", hour=0, minute=5)
scheduler.start()

# ─── HEALTHCHECK ──────────────────────────────────────────────────────────────
@app.get("/health", tags=["System"])
def health():
    return {"status": "ok", "timestamp": datetime.utcnow().isoformat()}
