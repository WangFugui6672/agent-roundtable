from __future__ import annotations

import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [("roundtables", "0004_message")]

    operations = [
        migrations.CreateModel(
            name="Turn",
            fields=[
                ("id", models.UUIDField(editable=False, primary_key=True, serialize=False)),
                ("round_number", models.PositiveSmallIntegerField()),
                (
                    "status",
                    models.CharField(
                        choices=[
                            ("pending", "待完成"),
                            ("completed", "已完成"),
                            ("passed", "已沉默"),
                            ("failed", "失败"),
                        ],
                        default="pending",
                        max_length=16,
                    ),
                ),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("completed_at", models.DateTimeField(blank=True, null=True)),
                (
                    "roundtable",
                    models.ForeignKey(
                        on_delete=django.db.models.deletion.CASCADE,
                        related_name="turns",
                        to="roundtables.roundtable",
                    ),
                ),
                (
                    "roundtable_agent",
                    models.ForeignKey(
                        on_delete=django.db.models.deletion.PROTECT,
                        related_name="turns",
                        to="roundtables.roundtableagent",
                    ),
                ),
            ],
            options={
                "db_table": "turn",
                "ordering": ["created_at", "id"],
                "constraints": [
                    models.UniqueConstraint(
                        fields=("roundtable_agent", "round_number"),
                        name="unique_turn_per_agent_round",
                    ),
                    models.UniqueConstraint(
                        condition=models.Q(("status", "pending")),
                        fields=("roundtable",),
                        name="unique_pending_turn_per_roundtable",
                    ),
                ],
            },
        ),
        migrations.AddField(
            model_name="message",
            name="round_number",
            field=models.PositiveSmallIntegerField(default=0),
        ),
        migrations.AddField(
            model_name="message",
            name="turn",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.PROTECT,
                related_name="messages",
                to="roundtables.turn",
            ),
        ),
    ]
