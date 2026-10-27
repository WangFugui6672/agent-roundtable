import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("roundtables", "0014_roundtable_last_activity_at_messagereport"),
    ]

    operations = [
        migrations.AddField(
            model_name="message",
            name="is_key_point",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="message",
            name="supersedes",
            field=models.OneToOneField(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.PROTECT,
                related_name="superseded_by",
                to="roundtables.message",
            ),
        ),
        migrations.AddField(
            model_name="turn",
            name="replaces_message",
            field=models.OneToOneField(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.PROTECT,
                related_name="regeneration_turn",
                to="roundtables.message",
            ),
        ),
        migrations.RemoveConstraint(
            model_name="turn",
            name="unique_turn_per_agent_round",
        ),
        migrations.AddConstraint(
            model_name="turn",
            constraint=models.UniqueConstraint(
                condition=models.Q(("replaces_message__isnull", True)),
                fields=("roundtable_agent", "round_number"),
                name="unique_turn_per_agent_round",
            ),
        ),
    ]
