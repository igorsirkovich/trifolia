﻿using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

using Trifolia.Logging;

namespace Trifolia.DB
{
    public partial class ValueSet
    {
        public static List<ValueSet> GetAllValueSets()
        {
            using (TemplateDatabaseDataSource tdb = new TemplateDatabaseDataSource())
            {
                return tdb.ValueSets.ToList();
            }
        }

        public List<ValueSetMember> GetActiveMembers(DateTime? bindingDate)
        {
            // Always have SOME desired date
            DateTime desiredStatusDate = bindingDate != null ? bindingDate.Value : DateTime.Now;

            // Include active members that either don't have a status date (assume should be included) or have a status date prior to the desired date
            List<ValueSetMember> members = this.Members
                .Where(y => (y.Status == "active" || string.IsNullOrEmpty(y.Status)) && (y.StatusDate == null || y.StatusDate <= desiredStatusDate))
                .ToList();

            var inactiveMembers = this.Members
                .Where(y => y.Status == "inactive" && (y.StatusDate == null || y.StatusDate <= desiredStatusDate));

            // Remove the active members that are inactivated after the status date of the inactivated member
            foreach (var cInactiveMember in inactiveMembers)
            {
                if (cInactiveMember.StatusDate == null)
                    members.Where(y => y.Code == cInactiveMember.Code && y.CodeSystem == cInactiveMember.CodeSystem)
                        .ToList()
                        .ForEach(y => members.Remove(y));
                else
                    members.Where(y => y.Code == cInactiveMember.Code && y.CodeSystem == cInactiveMember.CodeSystem && y.StatusDate != null && y.StatusDate <= cInactiveMember.StatusDate)
                        .ToList()
                        .ForEach(y => members.Remove(y));
            }

            return members;
        }
    }
}
