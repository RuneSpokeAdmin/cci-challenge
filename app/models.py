"""Data model for the widgets API."""
from __future__ import annotations

from .db import db


class Widget(db.Model):
    __tablename__ = "widgets"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120), nullable=False)
    quantity = db.Column(db.Integer, nullable=False, default=0)

    def to_dict(self) -> dict:
        return {"id": self.id, "name": self.name, "quantity": self.quantity}
