﻿<%@ Page Title="" Language="C#" MasterPageFile="~/Views/Shared/Site.MVC.Master" Inherits="System.Web.Mvc.ViewPage<dynamic>" %>

<asp:Content ID="Content2" ContentPlaceHolderID="HeadContent" runat="server">
    <style type="text/css">
        #OrganizationList .row {
            padding-top: 5px;
        }
    </style>
</asp:Content>

<asp:Content ID="Content1" ContentPlaceHolderID="MainContent" runat="server">
    <div id="OrganizationList" class="container-fluid">
        <h2>Organizations</h2>

        <div class="row">
            <div class="col-md-8"><strong>Name</strong></div>
            <div class="col-md-4">
                <div class="pull-right">
                    <button type="button" class="btn btn-primary" data-bind="click: function () { ShowAddOrganization(); }">Add</button>
                </div>
            </div>
        </div>
        
        <div data-bind="foreach: Organizations">
            <div class="row">
                <div class="col-md-8" data-bind="text: Name"></div>
                <div class="col-md-4">
                    <div class="pull-right">
                        <div class="btn-group">
                            <button type="button" class="btn btn-primary" data-bind="click: function () { EditDetails($data); }">Members & Groups</button>
                            <button type="button" class="btn btn-default" data-bind="click: function () { Delete($data); }">Delete</button>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <div class="modal fade" id="addOrganizationDialog">
            <div class="modal-dialog">
                <div class="modal-content">
                    <div class="modal-header">
                        <h4 class="modal-title">Add Organization</h4>
                    </div>
                    <div class="modal-body" data-bind="validationOptions: { messagesOnModified: false }">
                        <div class="form-group">
                            <label>New Organization Name</label>
                            <input type="text" class="form-control" data-bind="value: NewOrganizationName" />
                        </div>
                    </div>
                    <div class="modal-footer">
                        <button type="button" class="btn btn-primary" data-bind="click: AddOrganization, enable: NewOrganizationName.isValid">OK</button>
                        <button type="button" class="btn btn-default" data-bind="click: CancelAddOrganization">Cancel</button>
                    </div>
                </div>
                <!-- /.modal-content -->
            </div>
            <!-- /.modal-dialog -->
        </div>
        <!-- /.modal -->
    </div>

    <script type="text/javascript" src="/Scripts/Organization/List.js?<%= ViewContext.Controller.GetType().Assembly.GetName().Version %>"></script>
    <script type="text/javascript">
        var viewModel = null;
        $(document).ready(function () {
            viewModel = OrganizationListViewModel();
            ko.applyBindings(viewModel, $('#OrganizationList')[0]);

            $('#addOrganizationDialog').modal({
                show: false,
                keyboard: false,
                backdrop: 'static'
            });
        });
    </script>
</asp:Content>
