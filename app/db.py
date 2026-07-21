"""Shared SQLAlchemy instance, kept in its own module to avoid circular imports."""
from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()
