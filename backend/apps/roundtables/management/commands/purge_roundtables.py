from __future__ import annotations

from django.core.management.base import BaseCommand

from apps.roundtables.services import purge_expired_roundtables


class Command(BaseCommand):
    help = "Delete roundtables whose last activity is outside the retention window."

    def add_arguments(self, parser) -> None:
        parser.add_argument(
            "--dry-run",
            action="store_true",
            help="Report the number of expired roundtables without deleting anything.",
        )

    def handle(self, *args, **options) -> None:
        if options["dry_run"]:
            from datetime import timedelta

            from django.conf import settings
            from django.utils import timezone

            from apps.roundtables.models import Roundtable

            cutoff = timezone.now() - timedelta(days=settings.ROUNDTABLE_RETENTION_DAYS)
            count = Roundtable.objects.filter(last_activity_at__lte=cutoff).count()
            self.stdout.write(f"expired_roundtables={count} dry_run=true")
            return
        deleted = purge_expired_roundtables()
        self.stdout.write(f"deleted_roundtables={deleted}")
