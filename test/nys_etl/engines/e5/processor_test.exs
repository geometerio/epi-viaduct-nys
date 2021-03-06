defmodule NYSETL.Engines.E5.ProcessorTest do
  use NYSETL.DataCase, async: true

  import NYSETL.Test.TestHelpers
  alias NYSETL.Commcare
  alias NYSETL.ECLRS
  alias NYSETL.Engines.E5.Processor

  @user_id "2753ce1d42654b9897a3f88493838e34"

  def fixture(properties) when is_map(properties) do
    case_id = Ecto.UUID.generate()

    patient_case = %{
      "case_id" => case_id,
      "child_cases" => %{},
      "closed" => false,
      "date_closed" => nil,
      "date_modified" => "2020-06-04T13:43:10.375000Z",
      "domain" => "ny-somecounty-cdcms",
      "id" => case_id,
      "indexed_on" => "2020-06-04T13:43:10.907506",
      "indices" => %{},
      "opened_by" => "b08d0661a6fd40a3b2be2cc0d2760a8a",
      "properties" => properties,
      "resource_uri" => "",
      "server_date_modified" => "2020-06-04T13:43:10.465497Z",
      "server_date_opened" => "2020-06-01T18:55:09.622249Z",
      "user_id" => @user_id,
      "xform_ids" => ["01a5fc86-6572-40a2-a2c8-26ab09a8e05c", "52ef5142-6df7-473f-8a9d-58af58d7f4ca"]
    }

    {case_id, patient_case}
  end

  def with_child({case_id, case}, properties), do: {case_id, with_child(case, properties)}

  def with_child(case, properties) when is_map(properties) do
    {child_id, child} = fixture(properties)
    child = child |> Map.put("indices", %{"parent" => %{"case_id" => case["id"], "case_type" => "parent", "relationship" => "child"}})
    children = case["child_cases"] |> Map.put(child_id, child)
    case |> Map.put("child_cases", children)
  end

  setup do
    {:ok, _county} = ECLRS.find_or_create_county(12)

    county = %{
      display: "Some County",
      domain: "ny-somecounty-cdcms",
      fips: "12",
      gaz: "YAZ",
      location_id: "abc123456",
      name: "somecounty"
    }

    [county: county]
  end

  describe "process" do
    test "returns {:ok, case, :new_person} when no Person exists that matches case", context do
      {first_name, last_name, dob} = {"Glen", "Livet", "2001-01-02"}
      assert {:error, :not_found} = Commcare.get_person(dob: dob, name_first: "GLEN", name_last: "LIVET")

      {_case_id, patient_case} =
        fixture(%{
          "first_name" => first_name,
          "last_name" => last_name,
          "dob" => dob,
          "some" => "value"
        })

      index_case =
        Processor.process(case: patient_case, county: context.county)
        |> assert_ok(:new_person)

      assert {:ok, person} = Commcare.get_person(dob: dob, name_first: "GLEN", name_last: "LIVET")
      assert_eq(index_case.person_id, person.id)

      assert_eq(index_case.data, %{
        "first_name" => "Glen",
        "last_name" => "Livet",
        "dob" => dob,
        "some" => "value"
      })

      assert_eq([], person.patient_keys)
    end

    test "returns {:ok, case, :already_exists} an index case already exists for that case id and county", context do
      {case_id, case} =
        fixture(%{
          "external_id" => "9999#150000000",
          "first_name" => "Glen",
          "last_name" => "Livet",
          "other" => "thing"
        })

      {:ok, person} = Commcare.create_person(%{data: %{}, patient_keys: ["1234", "150000000"], name_first: nil, name_last: nil})

      {:ok, existing_index_case} =
        Commcare.create_index_case(%{case_id: case_id, data: %{"some" => "value", "other" => "stuff"}, person_id: person.id, county_id: 12})

      index_case =
        Processor.process(case: case, county: context.county)
        |> assert_ok(:already_exists)

      index_case.id |> assert_eq(existing_index_case.id)
      index_case.case_id |> assert_eq(case_id)
      index_case.county_id |> assert_eq(12)
      index_case.person_id |> assert_eq(person.id)

      index_case.data
      |> assert_eq(%{
        "external_id" => "9999#150000000",
        "first_name" => "Glen",
        "last_name" => "Livet",
        "some" => "value",
        "other" => "thing"
      })

      index_case |> assert_events(["updated_from_commcare"])
    end

    test "it does not save an event when the index case information is current", context do
      case_properties = %{
        "external_id" => "9999#150000000",
        "first_name" => "Glen",
        "last_name" => "Livet",
        "other" => "thing"
      }

      {case_id, case} = fixture(case_properties)

      {:ok, person} = Commcare.create_person(%{data: %{}, patient_keys: ["1234", "150000000"], name_first: nil, name_last: nil})

      {:ok, index_case} = Commcare.create_index_case(%{case_id: case_id, data: case_properties, person_id: person.id, county_id: 12})

      Processor.process(case: case, county: context.county)
      |> assert_ok(:already_exists)

      index_case |> assert_events([])
    end

    test "returns {:ok, index_case, :patient_key} when a Person can by found by patient_key extracted from a case", context do
      {:ok, person} = Commcare.create_person(%{data: %{}, patient_keys: ["1234", "150000000"], name_first: nil, name_last: nil})

      {case_id, case} =
        fixture(%{
          "external_id" => "9999#150000000",
          "first_name" => "Glen",
          "last_name" => "Livet"
        })

      index_case =
        Processor.process(case: case, county: context.county)
        |> assert_ok(:patient_key)

      index_case.case_id |> assert_eq(case_id)
      index_case.county_id |> assert_eq(12)
      index_case.person_id |> assert_eq(person.id)

      index_case |> assert_events(["retrieved_from_commcare"])
    end

    test "returns {:ok, index_case, :dob} when a Person can by found by dob and name extracted from a case", context do
      {:ok, person} =
        Commcare.create_person(%{
          data: %{},
          patient_keys: ["1234"],
          name_first: "GLEN",
          name_last: "LIVET",
          dob: ~D[2008-01-01]
        })

      {case_id, case} =
        fixture(%{
          "external_id" => "9999",
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2008-01-01"
        })

      index_case =
        Processor.process(case: case, county: context.county)
        |> assert_ok(:dob)

      index_case.case_id |> assert_eq(case_id)
      index_case.county_id |> assert_eq(12)
      index_case.person_id |> assert_eq(person.id)

      index_case |> assert_events(["retrieved_from_commcare"])
    end

    test "returns {:ok, index_case, :full_name} when a Person can by found by dob and full_name extracted from a case", context do
      {:ok, person} =
        Commcare.create_person(%{
          data: %{},
          patient_keys: ["1234"],
          name_first: "GLEN",
          name_last: "LIVET JONES",
          dob: ~D[2008-01-02]
        })

      {case_id, case} =
        fixture(%{
          "full_name" => "GLEN LIVET JONES",
          "dob" => "2008-01-02"
        })

      index_case =
        Processor.process(case: case, county: context.county)
        |> assert_ok(:full_name)

      index_case.case_id |> assert_eq(case_id)
      index_case.county_id |> assert_eq(12)
      index_case.person_id |> assert_eq(person.id)

      index_case |> assert_events(["retrieved_from_commcare"])
    end

    test "creates lab results when creating an index case", context do
      {:ok, _person} = Commcare.create_person(%{data: %{}, patient_keys: ["1234"]})

      {_case_id, case} =
        fixture(%{
          "external_id" => "9999#1234",
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2008-01-01"
        })
        |> with_child(%{
          "accession_number" => "ABC100001",
          "analysis_date" => "2020-05-22",
          "case_name" => " lab_result",
          "case_type" => "lab_result",
          "date_opened" => "2020-06-04T00:00:00.000000Z",
          "doh_mpi_id" => "9999",
          "external_id" => "9999#1234#ABC100001",
          "lab_result" => "positive",
          "laboratory" => "Access DX Laboratory, LLC",
          "owner_id" => @user_id,
          "specimen_collection_date" => "2020-05-22",
          "specimen_source" => "Nasopharyngeal Swab",
          "test_type" => "SARS coronavirus 2 RNA [Presence] in Unspecified s"
        })

      index_case =
        Processor.process(case: case, county: context.county)
        |> assert_ok(:patient_key)

      [lab_result] = index_case |> Repo.preload(:lab_results) |> Map.get(:lab_results)
      lab_result.case_id |> assert_eq(case["child_cases"] |> Map.keys() |> List.first())
      lab_result.accession_number |> assert_eq("ABC100001")

      lab_result.data
      |> assert_eq(%{
        "accession_number" => "ABC100001",
        "analysis_date" => "2020-05-22",
        "case_name" => " lab_result",
        "case_type" => "lab_result",
        "date_opened" => "2020-06-04T00:00:00.000000Z",
        "doh_mpi_id" => "9999",
        "external_id" => "9999#1234#ABC100001",
        "lab_result" => "positive",
        "laboratory" => "Access DX Laboratory, LLC",
        "owner_id" => @user_id,
        "specimen_collection_date" => "2020-05-22",
        "specimen_source" => "Nasopharyngeal Swab",
        "test_type" => "SARS coronavirus 2 RNA [Presence] in Unspecified s"
      })
    end

    test "creates lab results when creating a new person", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2008-01-01"
        })
        |> with_child(%{
          "accession_number" => "ABC100001",
          "analysis_date" => "2020-05-22",
          "case_name" => " lab_result",
          "case_type" => "lab_result",
          "date_opened" => "2020-06-04T00:00:00.000000Z",
          "doh_mpi_id" => "9999",
          "external_id" => "9999#1234#ABC100001",
          "lab_result" => "positive",
          "laboratory" => "Access DX Laboratory, LLC",
          "owner_id" => @user_id,
          "specimen_collection_date" => "2020-05-22",
          "specimen_source" => "Nasopharyngeal Swab",
          "test_type" => "SARS coronavirus 2 RNA [Presence] in Unspecified s"
        })

      index_case =
        Processor.process(case: patient_case, county: context.county)
        |> assert_ok(:new_person)

      [lab_result] = index_case |> Repo.preload(:lab_results) |> Map.get(:lab_results)
      lab_result.case_id |> assert_eq(patient_case["child_cases"] |> Map.keys() |> List.first())
      lab_result.accession_number |> assert_eq("ABC100001")

      lab_result.data
      |> assert_eq(%{
        "accession_number" => "ABC100001",
        "analysis_date" => "2020-05-22",
        "case_name" => " lab_result",
        "case_type" => "lab_result",
        "date_opened" => "2020-06-04T00:00:00.000000Z",
        "doh_mpi_id" => "9999",
        "external_id" => "9999#1234#ABC100001",
        "lab_result" => "positive",
        "laboratory" => "Access DX Laboratory, LLC",
        "owner_id" => @user_id,
        "specimen_collection_date" => "2020-05-22",
        "specimen_source" => "Nasopharyngeal Swab",
        "test_type" => "SARS coronavirus 2 RNA [Presence] in Unspecified s"
      })
    end

    test "skips lab results with no accession number", context do
      {:ok, _person} = Commcare.create_person(%{data: %{}, patient_keys: ["1234"]})

      {_case_id, case} =
        fixture(%{
          "external_id" => "9999#1234",
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2008-01-01"
        })
        |> with_child(%{
          "analysis_date" => "2020-05-22",
          "case_name" => " lab_result",
          "case_type" => "lab_result",
          "date_opened" => "2020-06-04T00:00:00.000000Z",
          "doh_mpi_id" => "",
          "external_id" => nil,
          "lab_result" => "positive",
          "laboratory" => "",
          "owner_id" => @user_id,
          "specimen_collection_date" => "2020-05-22",
          "specimen_source" => "Nasopharyngeal",
          "test_type" => "PCR"
        })

      index_case =
        Processor.process(case: case, county: context.county)
        |> assert_ok(:patient_key)

      index_case
      |> Repo.preload(:lab_results)
      |> Map.get(:lab_results)
      |> assert_eq([])
    end
  end

  describe "process - CommCare exclusion filters for cases not yet imported" do
    test "skips index cases where properties[final_disposition] IN (registered_in_error,duplicate,not_a_case)", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02",
          "final_disposition" => "registered_in_error"
        })

      Processor.process(case: patient_case, county: context.county)
      |> assert_eq({:error, :final_disposition})

      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02",
          "final_disposition" => "duplicate"
        })

      Processor.process(case: patient_case, county: context.county)
      |> assert_eq({:error, :final_disposition})

      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02",
          "final_disposition" => "not_a_case"
        })

      Processor.process(case: patient_case, county: context.county)
      |> assert_eq({:error, :final_disposition})
    end

    test "skips excluded index cases when the person is already known", context do
      {:ok, _person} = Commcare.create_person(%{data: %{}, patient_keys: [], name_first: "GLEN", name_last: "LIVET", dob: "2000-01-02"})

      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02",
          "final_disposition" => "registered_in_error"
        })

      Processor.process(case: patient_case, county: context.county)
      |> assert_eq({:error, :final_disposition})
    end

    test "returns {:ok, index_case, reason} for any other final_disposition", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02",
          "final_disposition" => "something_else"
        })

      Processor.process(case: patient_case, county: context.county)
      |> assert_ok(:new_person)
    end

    test "skips index cases where properties[stub]=yes", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02",
          "stub" => "yes"
        })

      Processor.process(case: patient_case, county: context.county)
      |> assert_eq({:error, :stub})
    end

    test "returns {:ok, index_case, reason} for any other stub", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02",
          "stub" => "no"
        })

      Processor.process(case: patient_case, county: context.county)
      |> assert_ok(:new_person)
    end

    test "skips index cases where closed=true (at the top-level)", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02"
        })

      patient_case = Map.put(patient_case, "closed", true)

      Processor.process(case: patient_case, county: context.county)
      |> assert_eq({:error, :closed})
    end

    test "returns {:ok, index_case, reason} for any other closed (at the top-level)", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02"
        })

      patient_case = Map.put(patient_case, "closed", nil)

      Processor.process(case: patient_case, county: context.county)
      |> assert_ok(:new_person)
    end

    test "skips index cases where current_status=closed and patient_type=pui", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02",
          "current_status" => "closed",
          "patient_type" => "pui"
        })

      Processor.process(case: patient_case, county: context.county)
      |> assert_eq({:error, :closed})
    end

    test "imports index cases where current_status=open and patient_type=pui", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02",
          "current_status" => "open",
          "patient_type" => "pui"
        })

      Processor.process(case: patient_case, county: context.county)
      |> assert_ok(:new_person)
    end

    test "imports index cases where current_status=closed and patient_type=confirmed", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02",
          "current_status" => "closed",
          "patient_type" => "confirmed"
        })

      Processor.process(case: patient_case, county: context.county)
      |> assert_ok(:new_person)
    end

    test "skips index cases where transfer_status IN (pending,sent)", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02",
          "transfer_status" => "pending"
        })

      Processor.process(case: patient_case, county: context.county)
      |> assert_eq({:error, :transfer_status})

      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02",
          "transfer_status" => "sent"
        })

      Processor.process(case: patient_case, county: context.county)
      |> assert_eq({:error, :transfer_status})
    end

    test "imports index cases where for any other transfer_status", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02",
          "transfer_status" => "something_else"
        })

      Processor.process(case: patient_case, county: context.county)
      |> assert_ok(:new_person)
    end

    test "skips index cases where the person has incomplete (name, DOB) or patient_key information", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "",
          "last_name" => "",
          "dob" => "2000-01-02"
        })

      assert {:error, _reason} = Processor.process(case: patient_case, county: context.county)
    end

    test "skips index cases with missing identifier information (even though patient_key is set - should not happen)", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "external_id" => "foobar#abc123"
        })

      assert {:error, _reason} = Processor.process(case: patient_case, county: context.county)
    end

    test "skips index cases with missing identifier information (even though name_and_id is set - should not happen)", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "name_and_id" => "Glen Livet (foobar#12345)"
        })

      assert {:error, _reason} = Processor.process(case: patient_case, county: context.county)
    end

    test "skips index cases with missing identifier information (even though lab result's external_id is set - should not happen)", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen"
        })
        |> with_child(%{
          "accession_number" => "ABC100001",
          "analysis_date" => "2020-05-22",
          "case_name" => " lab_result",
          "case_type" => "lab_result",
          "date_opened" => "2020-06-04T00:00:00.000000Z",
          "doh_mpi_id" => "9999",
          "external_id" => "9999#1234#ABC100001",
          "lab_result" => "positive",
          "laboratory" => "Access DX Laboratory, LLC",
          "owner_id" => @user_id,
          "specimen_collection_date" => "2020-05-22",
          "specimen_source" => "Nasopharyngeal Swab",
          "test_type" => "SARS coronavirus 2 RNA [Presence] in Unspecified s"
        })

      assert {:error, _reason} = Processor.process(case: patient_case, county: context.county)
    end
  end

  describe "process - CommCare exclusion filters for cases previously imported" do
    setup context do
      case_id = Ecto.UUID.generate()

      {:ok, person} = Commcare.create_person(%{data: %{}, patient_keys: [], name_first: "Glen", name_last: "Livet", dob: "2000-01-02"})

      {:ok, existing_index_case} = Commcare.create_index_case(%{case_id: case_id, data: %{}, person_id: person.id, county_id: 12})

      [county: context.county, case_id: case_id, existing_index_case: existing_index_case]
    end

    test "updates existing cases to set properties[final_disposition] IN (registered_in_error,duplicate,not_a_case)", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02",
          "final_disposition" => "registered_in_error"
        })

      patient_case = Map.put(patient_case, "case_id", context.case_id)

      index_case =
        Processor.process(case: patient_case, county: context.county)
        |> assert_ok(:already_exists)

      index_case.id |> assert_eq(context.existing_index_case.id)

      index_case.data
      |> assert_eq(%{
        "first_name" => "Glen",
        "last_name" => "Livet",
        "dob" => "2000-01-02",
        "final_disposition" => "registered_in_error"
      })

      index_case |> assert_events(["updated_from_commcare"])

      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02",
          "final_disposition" => "duplicate"
        })

      patient_case = Map.put(patient_case, "case_id", context.case_id)

      index_case =
        Processor.process(case: patient_case, county: context.county)
        |> assert_ok(:already_exists)

      index_case.id |> assert_eq(context.existing_index_case.id)

      index_case.data
      |> assert_eq(%{
        "first_name" => "Glen",
        "last_name" => "Livet",
        "dob" => "2000-01-02",
        "final_disposition" => "duplicate"
      })

      index_case |> assert_events(["updated_from_commcare", "updated_from_commcare"])

      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02",
          "final_disposition" => "not_a_case"
        })

      patient_case = Map.put(patient_case, "case_id", context.case_id)

      index_case =
        Processor.process(case: patient_case, county: context.county)
        |> assert_ok(:already_exists)

      index_case.id |> assert_eq(context.existing_index_case.id)

      index_case.data
      |> assert_eq(%{
        "first_name" => "Glen",
        "last_name" => "Livet",
        "dob" => "2000-01-02",
        "final_disposition" => "not_a_case"
      })

      index_case |> assert_events(["updated_from_commcare", "updated_from_commcare", "updated_from_commcare"])
    end

    test "updates existing cases to set properties[stub]=yes", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02",
          "stub" => "yes"
        })

      patient_case = Map.put(patient_case, "case_id", context.case_id)

      index_case =
        Processor.process(case: patient_case, county: context.county)
        |> assert_ok(:already_exists)

      index_case.id |> assert_eq(context.existing_index_case.id)

      index_case.data
      |> assert_eq(%{
        "first_name" => "Glen",
        "last_name" => "Livet",
        "dob" => "2000-01-02",
        "stub" => "yes"
      })

      index_case |> assert_events(["updated_from_commcare"])
    end

    test "updates existing cases to set closed=true (at the top-level)", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02"
        })

      patient_case = patient_case |> Map.put("case_id", context.case_id) |> Map.put("closed", true)

      index_case =
        Processor.process(case: patient_case, county: context.county)
        |> assert_ok(:already_exists)

      index_case.id |> assert_eq(context.existing_index_case.id)

      assert index_case.closed
      index_case |> assert_events(["updated_from_commcare"])
    end

    test "updates existing cases to set current_status=closed and patient_type=pui", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02",
          "current_status" => "closed",
          "patient_type" => "pui"
        })

      patient_case = Map.put(patient_case, "case_id", context.case_id)

      index_case =
        Processor.process(case: patient_case, county: context.county)
        |> assert_ok(:already_exists)

      index_case.id |> assert_eq(context.existing_index_case.id)

      index_case.data
      |> assert_eq(%{
        "first_name" => "Glen",
        "last_name" => "Livet",
        "dob" => "2000-01-02",
        "current_status" => "closed",
        "patient_type" => "pui"
      })

      index_case |> assert_events(["updated_from_commcare"])
    end

    test "updates existing cases to set transfer_status IN (pending,sent)", context do
      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02",
          "transfer_status" => "pending"
        })

      patient_case = Map.put(patient_case, "case_id", context.case_id)

      index_case =
        Processor.process(case: patient_case, county: context.county)
        |> assert_ok(:already_exists)

      index_case.id |> assert_eq(context.existing_index_case.id)

      index_case.data
      |> assert_eq(%{
        "first_name" => "Glen",
        "last_name" => "Livet",
        "dob" => "2000-01-02",
        "transfer_status" => "pending"
      })

      index_case |> assert_events(["updated_from_commcare"])

      {_case_id, patient_case} =
        fixture(%{
          "first_name" => "Glen",
          "last_name" => "Livet",
          "dob" => "2000-01-02",
          "transfer_status" => "sent"
        })

      patient_case = Map.put(patient_case, "case_id", context.case_id)

      index_case =
        Processor.process(case: patient_case, county: context.county)
        |> assert_ok(:already_exists)

      index_case.id |> assert_eq(context.existing_index_case.id)

      index_case.data
      |> assert_eq(%{
        "first_name" => "Glen",
        "last_name" => "Livet",
        "dob" => "2000-01-02",
        "transfer_status" => "sent"
      })

      index_case |> assert_events(["updated_from_commcare", "updated_from_commcare"])
    end
  end
end
