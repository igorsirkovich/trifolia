﻿var emailNameRequired;

var requireEmailandName = function (logIn) {
    emailNameRequired = logIn;
}

var SupportRequest = function () {
    var self = this;

    self.showEmailName = ko.observable(emailNameRequired);
    self.Name = ko.observable();
    self.Email = ko.observable();
    self.Priority = ko.observable();
    self.Summary = ko.observable();
    self.Type = ko.observable();
    self.Details = ko.observable();

    var validation = ko.validatedObservable({
        Name: self.Name.extend({ required: emailNameRequired }),
        Email: self.Email.extend({ required: emailNameRequired }),
        Summary: self.Summary.extend({ required: true, maxLength: 254 }),
        Details: self.Details.extend({ required: true })
    });

    self.IsValid = ko.computed(function () {
        return validation.isValid();
    });
}

var SupportViewModel = function () {
    var self = this;

    self.Config = ko.observable();

    self.ShowSupportLink = ko.computed(function () {
        return self.Config() && self.Config().RedirectUrl &&
            !(self.Config().EnableJiraSupport || self.Config().EmailConfigured);
    });

    self.ShowSupportPopup = ko.computed(function () {
        //We don't care if there's a RedirectURL set as long as JIRA or a designated email address is available.
        return self.Config() && (self.Config().EnableJiraSupport || self.Config().EmailConfigured);
    });

    $.ajax({
        async: false,
        url: '/api/Auth/WhoAmI',
        complete: function (jqXHR, textstatus) {
            requireEmailandName(!jqXHR.responseJSON);
        }
    });

    $.ajax({
        type: "GET",
        url: "/api/Support/SupportMethodCheck",
        success: function (data, textStatus, jqXHR) {
            self.Config(data);
        },
        error: function (jqXHR, textStatus, errorThrown) {
            alert('There was an error determining what the designated support method is.');
        }
    });

    self.Request = ko.observable(new SupportRequest());

    self.SubmitSupportRequest = function () {
        if (!self.Request().IsValid()) {
            alert('Please fix any validation errors before submitting.');
            return;
        }

        $("#supportPopup").block();

        var data = {
            "Name": self.Request().Name(),
            "Email": self.Request().Email(),
            "Summary": self.Request().Summary(),
            "Type": self.Request().Type(),
            "Priority": self.Request().Priority(),
            "Details": self.Request().Details()
        };

        $.ajax({
            type: "POST",
            url: "/api/Support",
            data: data,
            success: function(data, textStatus, jqXHR) {
                if (data == 'Email sent') {
                    alert('JIRA Support Request email successfully sent.');
                } else if (data == "Could not submit beta user application.  Please notify the administrator") {
                    alert('JIRA Support Request email unable to be successfully sent with error: "Could not ' +
                        'submit beta user application.  Please notify the administrator"');
                } else {
                    alert('Successfully created JIRA support request: ' + data);
                    self.CancelSupportRequest();
                }
            },
            error: function(jqXHR, textStatus, errorThrown) {
                alert('There was an error submitting your support request: ' + errorThrown);
            },
            complete: function (jqXHR, textStatus) {
                $("#supportPopup").unblock();
            }
        });
    };

    self.CancelSupportRequest = function () {
        $("#supportPopup").modal('hide');
        self.Request(new SupportRequest());
    };

    self.ShowSupportRequest = function ()
    {
        $("#supportPopup").modal('show');  
    };
};