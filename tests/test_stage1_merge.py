from agent.stage1.geo import haversine_m
from agent.stage1.rules import Flag, check_geo, check_photo_completeness
from agent.merge.itog import Itog, MergeInput, PhotoVerdict, merge_itog
from agent.stage2.routing import Checklist, route_checklist


def test_haversine_same_point():
    assert haversine_m(56.85, 53.2, 56.85, 53.2) < 1e-6


def test_photo_completeness():
    assert check_photo_completeness(2).flag == Flag.OK
    assert check_photo_completeness(1).flag == Flag.FAIL


def test_geo_at_least_one():
    r = check_geo([150.0, 50.0, None], radius_m=100)
    assert r.flag == Flag.OK
    assert r.detail["ГЕО_МИН_М"] == 50.0


def test_merge_photo_beats_schedule():
    itog = merge_itog(
        MergeInput(
            photo_verdict=PhotoVerdict.VIOLATION,
            geo_fail=False,
            geo_na_no_coords=False,
            schedule_fail=True,
            special_human=False,
        )
    )
    assert itog == Itog.PHOTO


def test_route_rso():
    assert route_checklist(state="Выполнено", waste_type="РСО", site_type="Контейнерная площадка") == Checklist.RSO
