﻿extern alias fhir_stu3;
using fhir_stu3.Hl7.Fhir.Model;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Web.Http;
using Trifolia.Authorization;
using Trifolia.DB;
using Trifolia.Export.FHIR.STU3;
using Trifolia.Import.FHIR.STU3;
using Trifolia.Shared.FHIR;
using FhirValueSet = fhir_stu3.Hl7.Fhir.Model.ValueSet;
using ValueSet = Trifolia.DB.ValueSet;

namespace Trifolia.Web.Controllers.API.FHIR.STU3
{
    [STU3Config]
    [RoutePrefix("api/FHIR3")]
    public class FHIR3ValueSetController : ApiController
    {
        private IObjectRepository tdb;

        #region Constructors

        public FHIR3ValueSetController(IObjectRepository tdb)
        {
            this.tdb = tdb;
        }

        public FHIR3ValueSetController()
            : this(new TemplateDatabaseDataSource())
        {

        }

        #endregion

        /// <summary>
        /// Gets the specified value set from Trifolia, converts it to, and returns a ValueSet resource.
        /// </summary>
        /// <param name="valueSetId">The id of the value set to search for. If specified and found, only a single ValueSet resource is returned in the Bundle.</param>
        /// <param name="format">Optional. The format to respond with (ex: "application/fhir+xml" or "application/fhir+json")</param>
        /// <param name="summary">Optional. The type of summary to respond with.</param>
        /// <returns>Hl7.Fhir.Model.ValueSet</returns>
        /// <permission cref="Trifolia.Authorization.SecurableNames.VALUESET_LIST">Only users with the ability to list value sets can execute this operation</permission>
        [HttpGet]
        [Route("ValueSet/{valueSetId}")]
        [SecurableAction(SecurableNames.VALUESET_LIST)]
        public HttpResponseMessage GetValueSet(
            [FromUri] int valueSetId,
            [FromUri(Name = "_format")] string format = null,
            [FromUri(Name = "_summary")] SummaryType? summary = null)
        {
            ValueSet valueSet = this.tdb.ValueSets.Single(y => y.Id == valueSetId);
            ValueSetExporter exporter = new ValueSetExporter(this.tdb);
            FhirValueSet fhirValueSet = exporter.Convert(valueSet, summary);

            return Shared.GetResponseMessage(this.Request, format, fhirValueSet);
        }

        /// <summary>
        /// Searches value sets within Trifolia and returns them as ValueSet resources within a Bundle.
        /// </summary>
        /// <param name="name">The name of the value set to search for</param>
        /// <param name="valueSetId">The id of the value set to search for. If specified and found, only a single ValueSet resource is returned in the Bundle.</param>
        /// <param name="format">Optional. The format to respond with (ex: "application/fhir+xml" or "application/fhir+json")</param>
        /// <param name="summary">Optional. The type of summary to respond with.</param>
        /// <returns>Hl7.Fhir.Model.Bundle&lt;Hl7.Fhir.Model.ValueSet&gt;</returns>
        /// <permission cref="Trifolia.Authorization.SecurableNames.VALUESET_LIST">Only users with the ability to list value sets can execute this operation</permission>
        [HttpGet]
        [Route("ValueSet")]
        [Route("ValueSet/_search")]
        [SecurableAction]
        public HttpResponseMessage GetValueSets(
            [FromUri(Name = "_id")] int? valueSetId = null,
            [FromUri(Name = "name")] string name = null,
            [FromUri(Name = "_format")] string format = null,
            [FromUri(Name = "_summary")] SummaryType? summary = null)
        {
            var valueSets = this.tdb.ValueSets.Where(y => y.Id >= 0);
            ValueSetExporter exporter = new ValueSetExporter(this.tdb);

            if (valueSetId != null)
                valueSets = valueSets.Where(y => y.Id == valueSetId);

            if (!string.IsNullOrEmpty(name))
                valueSets = valueSets.Where(y => y.Name.ToLower().Contains(name.ToLower()));

            Bundle bundle = new Bundle()
            {
                Type = Bundle.BundleType.BatchResponse
            };

            var publishedValueSets = (from ig in this.tdb.ImplementationGuides
                                      join t in this.tdb.Templates on ig.Id equals t.OwningImplementationGuideId
                                      join tc in this.tdb.TemplateConstraints on t.Id equals tc.TemplateId
                                      where ig.PublishStatus != null && ig.PublishStatus.Status == PublishStatus.PUBLISHED_STATUS && tc.ValueSet != null
                                      select tc.ValueSet)
                                      .ToList();  // Query the database immediately
            
            foreach (var valueSet in valueSets)
            {
                var fhirValueSet = exporter.Convert(valueSet, summary, publishedValueSets);
                var fullUrl = string.Format("{0}://{1}/api/FHIR3/{2}",
                    this.Request.RequestUri.Scheme,
                    this.Request.RequestUri.Authority,
                    fhirValueSet.Url);

                bundle.AddResourceEntry(fhirValueSet, fullUrl);
            }

            return Shared.GetResponseMessage(this.Request, format, bundle);
        }

        [HttpPost]
        [Route("ValueSet")]
        [SecurableAction(SecurableNames.VALUESET_EDIT)]
        public HttpResponseMessage CreateValueSet(
            [FromBody] FhirValueSet fhirValueSet,
            [FromUri(Name = "_format")] string format = null)
        {
            var fhirIdentifier = fhirValueSet.Identifier.Count > 0 ? fhirValueSet.Identifier.First() : null;
            var fhirIdentifierValue = fhirIdentifier != null ? fhirIdentifier.Value : null;

            if (fhirValueSet.Identifier != null && this.tdb.ValueSets.Count(y => y.Oid == fhirIdentifierValue) > 0)
                throw new Exception("ValueSet already exists with this identifier. Use a PUT instead");

            ValueSetImporter importer = new ValueSetImporter(this.tdb);
            ValueSetExporter exporter = new ValueSetExporter(this.tdb);
            ValueSet valueSet = importer.Convert(fhirValueSet);

            if (valueSet.Oid == null)
                valueSet.Oid = string.Empty;

            if (this.tdb.ValueSets.Count(y => y.Oid == valueSet.Oid) > 0)
                throw new Exception("A ValueSet with that identifier already exists");

            this.tdb.ValueSets.AddObject(valueSet);
            this.tdb.SaveChanges();

            string location = string.Format("{0}://{1}/api/FHIR3/ValueSet/{2}",
                    this.Request.RequestUri.Scheme,
                    this.Request.RequestUri.Authority,
                    fhirValueSet.Id);

            Dictionary<string, string> headers = new Dictionary<string, string>();
            headers.Add("Location", location);

            FhirValueSet createdFhirValueSet = exporter.Convert(valueSet);
            return Shared.GetResponseMessage(this.Request, format, createdFhirValueSet, statusCode: 201, headers: headers);
        }

        [HttpPut]
        [Route("ValueSet/{valueSetId}")]
        [SecurableAction(SecurableNames.VALUESET_EDIT)]
        public HttpResponseMessage UpdateValueSet(
            [FromBody] FhirValueSet fhirValueSet,
            [FromUri] int valueSetId,
            [FromUri(Name = "_format")] string format = null)
        {
            ValueSetExporter exporter = new ValueSetExporter(this.tdb);
            ValueSetImporter importer = new ValueSetImporter(this.tdb);
            ValueSet originalValueSet = this.tdb.ValueSets.Single(y => y.Id == valueSetId);
            ValueSet newValueSet = importer.Convert(fhirValueSet, valueSet: originalValueSet);

            if (originalValueSet == null)
                this.tdb.ValueSets.AddObject(newValueSet);

            this.tdb.SaveChanges();

            string location = string.Format("{0}://{1}/api/FHIR3/ValueSet/{2}",
                    this.Request.RequestUri.Scheme,
                    this.Request.RequestUri.Authority,
                    fhirValueSet.Id);

            Dictionary<string, string> headers = new Dictionary<string, string>();
            headers.Add("Location", location);

            FhirValueSet updatedFhirValueSet = exporter.Convert(newValueSet);
            return Shared.GetResponseMessage(this.Request, format, updatedFhirValueSet, originalValueSet != null ? 200 : 201, headers);
        }
    }
}
