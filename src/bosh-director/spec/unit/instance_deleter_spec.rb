require 'spec_helper'

module Bosh::Director
  describe InstanceDeleter do
    before { allow(App).to receive_message_chain(:instance, :blobstores, :blobstore).and_return(blobstore) }
    let(:blobstore) { instance_double('Bosh::Blobstore::Client') }
    let(:domain) { Models::Dns::Domain.make(name: 'bosh') }
    let(:cloud_factory) { instance_double(Bosh::Director::CloudFactory) }
    let(:cloud) { instance_double(Bosh::Clouds::ExternalCpi) }
    let(:delete_job) { Jobs::DeleteDeployment.new('test_deployment', {}) }
    let(:task) { Bosh::Director::Models::Task.make(id: 42, username: 'user') }

    before do
      allow(delete_job).to receive(:task_id).and_return(task.id)
      allow(Config).to receive(:current_job).and_return(delete_job)
      allow(Bosh::Director::Config).to receive(:record_events).and_return(true)
      allow(BlobstoreDnsPublisher).to receive(:new).and_return(dns_publisher)
      allow(LocalDnsRepo).to receive(:new).and_return(local_dns_repo)
      allow(Bosh::Director::CloudFactory).to receive(:create).and_return(cloud_factory)
      allow(cloud_factory).to receive(:get).with('', 25).and_return(cloud)
    end

    let(:ip_provider) { instance_double(DeploymentPlan::IpProvider) }
    let(:powerdns_manager) { instance_double(PowerDnsManager, delete_dns_for_instance: nil) }
    let(:dns_publisher) { instance_double(BlobstoreDnsPublisher, publish_and_broadcast: nil) }
    let(:local_dns_repo) { instance_double(LocalDnsRepo, delete_for_instance: nil) }

    let(:options) { {} }
    let(:deleter) { InstanceDeleter.new(ip_provider, powerdns_manager, disk_manager, options) }
    let(:disk_manager) { DiskManager.new(logger) }

    describe '#delete_instance_plans' do
      let(:network_plan) { DeploymentPlan::NetworkPlanner::Plan.new(reservation: reservation) }

      let(:existing_vm) { Models::Vm.make(cid: 'fake-vm-cid', instance_id: existing_instance.id, stemcell_api_version: 25) }
      let(:existing_instance) do
        Models::Instance.make(deployment: deployment_model, uuid: 'my-uuid-1', job: 'fake-job-name', index: 5)
      end

      let(:instance_plan) do
        DeploymentPlan::InstancePlan.new(
          existing_instance: existing_instance,
          instance: nil,
          network_plans: [network_plan],
          desired_instance: nil,
          skip_drain: true,
        )
      end

      let(:instance_plans_to_delete) do
        instance_plans = []
        5.times { instance_plans << instance_plan }
        instance_plans
      end

      let(:instances_to_delete) do
        instances = []
        5.times { instances << instance_plan.instance }
        instances
      end

      let(:event_log_stage) { instance_double('Bosh::Director::EventLog::Stage') }

      before do
        existing_instance.active_vm = existing_vm
        existing_instance.save
      end

      describe 'deleting instances' do
        let(:network) { instance_double(DeploymentPlan::ManualNetwork, name: 'manual-network') }
        let(:reservation) do
          az = DeploymentPlan::AvailabilityZone.new('az', {})
          instance = DeploymentPlan::Instance.create_from_instance_group(job, 5, {}, deployment_plan, 'started', az, logger)
          reservation = DesiredNetworkReservation.new(instance.model, network, '192.168.1.2', :dynamic)
          reservation.mark_reserved

          reservation
        end

        let(:deployment_model) { Models::Deployment.make(name: 'deployment-name') }
        let(:job) { DeploymentPlan::InstanceGroup.new(logger) }
        let(:deployment_plan) { instance_double(DeploymentPlan::Planner, ip_provider: ip_provider, model: deployment_model) }
        let(:stopper) { instance_double(Stopper) }
        let(:job_templates_cleaner) do
          job_templates_cleaner = instance_double('Bosh::Director::RenderedJobTemplatesCleaner')

          allow(RenderedJobTemplatesCleaner).to receive(:new)
            .with(existing_instance, blobstore, logger).and_return(job_templates_cleaner)

          job_templates_cleaner
        end

        let(:persistent_disks) do
          disk = Models::PersistentDisk.make(disk_cid: 'fake-disk-cid-1')
          Models::Snapshot.make(persistent_disk: disk)
          [Models::PersistentDisk.make(disk_cid: 'instance-disk-cid'), disk]
        end

        let(:vm_deleter) { VmDeleter.new(logger, false, false) }

        before do
          allow(event_log_stage).to receive(:advance_and_track).and_yield

          allow(VmDeleter).to receive(:new).and_return(vm_deleter)
          allow(Stopper).to receive(:new).with(instance_plan, 'stopped', Config, logger).and_return(stopper)

          allow(stopper).to receive(:stop)
          allow(vm_deleter).to receive(:delete_for_instance).and_call_original

          persistent_disks.each { |disk| existing_instance.persistent_disks << disk }
        end

        it 'should delete the instances with the config max threads option' do
          allow(Config).to receive(:max_threads).and_return(5)
          pool = double('pool')
          expect(ThreadPool).to receive(:new).with(max_threads: 5).and_return(pool)
          expect(pool).to receive(:wrap).and_yield(pool)
          expect(pool).to receive(:process).exactly(5).times.and_yield

          5.times do |index|
            expect(deleter).to receive(:delete_instance_plan).with(
              instance_plans_to_delete[index],
              event_log_stage,
            )
          end

          deleter.delete_instance_plans(instance_plans_to_delete, event_log_stage)
        end

        it 'should record deletion event' do
          expect(stopper).to receive(:stop)
          expect(vm_deleter).to receive(:delete_for_instance).with(existing_instance, true, true).and_call_original
          expect(cloud).to receive(:delete_vm).with(existing_instance.vm_cid)
          expect(ip_provider).to receive(:release).with(reservation)
          expect(event_log_stage).to receive(:advance_and_track).with('fake-job-name/my-uuid-1 (5)')

          expect do
            deleter.delete_instance_plans([instance_plan], event_log_stage)
          end.to change { Bosh::Director::Models::Event.count }.from(0).to(8)

          event1 = Bosh::Director::Models::Event.order(:id).first
          expect(event1.user).to eq(task.username)
          expect(event1.action).to eq('delete')
          expect(event1.object_type).to eq('instance')
          expect(event1.object_name).to eq('fake-job-name/my-uuid-1')
          expect(event1.task).to eq(task.id.to_s)
          expect(event1.deployment).to eq('deployment-name')
          expect(event1.instance).to eq('fake-job-name/my-uuid-1')

          event2 = Bosh::Director::Models::Event.order(:id).last
          expect(event2.parent_id).to eq(1)
          expect(event2.user).to eq(task.username)
          expect(event2.action).to eq('delete')
          expect(event2.object_type).to eq('instance')
          expect(event2.object_name).to eq('fake-job-name/my-uuid-1')
          expect(event2.task).to eq(task.id.to_s)
          expect(event2.deployment).to eq('deployment-name')
          expect(event2.instance).to eq('fake-job-name/my-uuid-1')
        end

        it 'should record deletion event with error' do
          allow(stopper).to receive(:stop).and_raise(RpcTimeout)

          expect do
            deleter.delete_instance_plans([instance_plan], event_log_stage)
          end.to raise_error RpcTimeout

          event2 = Bosh::Director::Models::Event.order(:id).last
          expect(event2.error).to eq('Bosh::Director::RpcTimeout')
        end

        it 'should delete the instances with the respected max threads option' do
          pool = double('pool')
          expect(ThreadPool).to receive(:new).with(max_threads: 2).and_return(pool)
          expect(pool).to receive(:wrap).and_yield(pool)
          expect(pool).to receive(:process).exactly(5).times.and_yield

          5.times do |index|
            expect(deleter).to receive(:delete_instance_plan)
              .with(instance_plans_to_delete[index], event_log_stage)
          end

          deleter.delete_instance_plans(instance_plans_to_delete, event_log_stage, max_threads: 2)
        end

        it 'drains, deletes snapshots, dns records, persistent disk, releases old reservations' do
          expect(stopper).to receive(:stop)
          expect(powerdns_manager).to receive(:delete_dns_for_instance).with(existing_instance)

          expect(dns_publisher).to receive(:publish_and_broadcast)
          expect(local_dns_repo).to receive(:delete_for_instance)

          expect(cloud).to receive(:delete_vm).with(existing_instance.vm_cid)
          expect(ip_provider).to receive(:release).with(reservation)

          expect(event_log_stage).to receive(:advance_and_track).with('fake-job-name/my-uuid-1 (5)')

          job_templates_cleaner = instance_double('Bosh::Director::RenderedJobTemplatesCleaner')

          allow(RenderedJobTemplatesCleaner).to receive(:new)
            .with(existing_instance, blobstore, logger).and_return(job_templates_cleaner)

          expect(job_templates_cleaner).to receive(:clean_all).with(no_args)
          expect(disk_manager).to receive(:delete_persistent_disks).with(existing_instance)

          expect do
            deleter.delete_instance_plans([instance_plan], event_log_stage)
          end.to change { Models::Instance.all.select { |i| i.active_vm == existing_vm }.count }.from(1).to(0)
        end

        context 'when the instance has an unresponsive agent' do
          before do
            allow(instance_plan).to receive(:unresponsive_agent?).and_return(true)
          end

          it 'should delete the instance synchronously' do
            expect(stopper).to receive(:stop)
            expect(vm_deleter).to receive(:delete_for_instance).with(existing_instance, true, false).and_call_original
            expect(cloud).to receive(:delete_vm).with(existing_instance.vm_cid)
            expect(ip_provider).to receive(:release).with(reservation)
            expect(event_log_stage).to receive(:advance_and_track).with('fake-job-name/my-uuid-1 (5)')

            expect do
              deleter.delete_instance_plans([instance_plan], event_log_stage)
            end.to change { Bosh::Director::Models::Event.count }.from(0).to(8)
          end
        end

        context 'when force option is passed in' do
          let(:vm_deleter) { VmDeleter.new(logger, true, false) }
          let(:options) { { force: true } }

          context 'when stopping fails' do
            before do
              allow(stopper).to receive(:stop).and_raise(RpcTimeout)
            end

            it 'deletes snapshots, persistent disk, releases old reservations' do
              expect(VmDeleter).to receive(:new).with(anything, true, false)
              expect(disk_manager).to receive(:delete_persistent_disks).with(existing_instance)
              expect(powerdns_manager).to receive(:delete_dns_for_instance).with(existing_instance)

              expect(dns_publisher).to receive(:publish_and_broadcast)
              expect(local_dns_repo).to receive(:delete_for_instance)

              expect(cloud).to receive(:delete_vm).with(existing_instance.vm_cid)
              expect(ip_provider).to receive(:release).with(reservation)

              expect(event_log_stage).to receive(:advance_and_track).with('fake-job-name/my-uuid-1 (5)')

              expect(job_templates_cleaner).to receive(:clean_all).with(no_args)

              expect do
                deleter.delete_instance_plans([instance_plan], event_log_stage)
              end.to change { Models::Instance.all.select { |i| i.active_vm == existing_vm }.count }.from(1).to(0)
            end
          end

          context 'when deleting vm fails' do
            before do
              allow(cloud).to receive(:delete_vm)
                .and_raise(Bosh::Clouds::CloudError.new('Failed to create VM'))
            end

            it 'drains, deletes snapshots, persistent disk, releases old reservations' do
              expect(stopper).to receive(:stop)
              expect(disk_manager).to receive(:delete_persistent_disks).with(existing_instance)
              expect(powerdns_manager).to receive(:delete_dns_for_instance).with(existing_instance)

              expect(dns_publisher).to receive(:publish_and_broadcast)
              expect(local_dns_repo).to receive(:delete_for_instance)

              expect(ip_provider).to receive(:release).with(reservation)

              expect(event_log_stage).to receive(:advance_and_track).with('fake-job-name/my-uuid-1 (5)')

              expect(job_templates_cleaner).to receive(:clean_all).with(no_args)

              expect do
                deleter.delete_instance_plans([instance_plan], event_log_stage)
              end.to change { Models::Instance.all.select { |i| i.active_vm == existing_vm }.count }.from(1).to(0)
            end
          end

          context 'when deleting dns fails' do
            before do
              allow(powerdns_manager).to receive(:delete_dns_for_instance).and_raise('failed')

              allow(dns_publisher).to receive(:publish_and_broadcast)
              allow(local_dns_repo).to receive(:delete_for_instance)
            end

            it 'drains, deletes vm, snapshots, disks, releases old reservations' do
              expect(stopper).to receive(:stop)
              expect(cloud).to receive(:delete_vm).with(existing_instance.vm_cid)
              expect(disk_manager).to receive(:delete_persistent_disks).with(existing_instance)
              expect(ip_provider).to receive(:release).with(reservation)

              expect(event_log_stage).to receive(:advance_and_track).with('fake-job-name/my-uuid-1 (5)')

              expect(job_templates_cleaner).to receive(:clean_all).with(no_args)

              expect do
                deleter.delete_instance_plans([instance_plan], event_log_stage)
              end.to change { Models::Instance.all.select { |i| i.active_vm == existing_vm }.count }.from(1).to(0)
            end
          end

          context 'when cleaning templates fails' do
            before do
              allow(job_templates_cleaner).to receive(:clean_all).and_raise('failed')
            end

            it 'drains, deletes vm, snapshots, disks, releases old reservations' do
              expect(stopper).to receive(:stop)
              expect(cloud).to receive(:delete_vm).with(existing_instance.vm_cid)
              expect(disk_manager).to receive(:delete_persistent_disks).with(existing_instance)
              expect(ip_provider).to receive(:release).with(reservation)

              expect(event_log_stage).to receive(:advance_and_track).with('fake-job-name/my-uuid-1 (5)')
              expect(job_templates_cleaner).to receive(:clean_all).with(no_args)

              expect do
                deleter.delete_instance_plans([instance_plan], event_log_stage)
              end.to change { Models::Instance.all.select { |i| i.active_vm == existing_vm }.count }.from(1).to(0)
            end
          end
        end

        context 'when virtual_delete_vm option is passed in' do
          let(:vm_deleter) { VmDeleter.new(logger, false, true) }
          let(:options) { { virtual_delete_vm: true } }

          it 'deletes snapshots, persistent disk, releases old reservations, vm should not be deleted from cloud' do
            expect(VmDeleter).to receive(:new).with(anything, anything, true)
            expect(stopper).to receive(:stop)
            expect(cloud).not_to receive(:delete_vm)

            expect(disk_manager).to receive(:delete_persistent_disks).with(existing_instance)
            expect(powerdns_manager).to receive(:delete_dns_for_instance).with(existing_instance)

            expect(dns_publisher).to receive(:publish_and_broadcast)
            expect(local_dns_repo).to receive(:delete_for_instance)

            expect(ip_provider).to receive(:release).with(reservation)

            expect(event_log_stage).to receive(:advance_and_track).with('fake-job-name/my-uuid-1 (5)')
            expect(job_templates_cleaner).to receive(:clean_all).with(no_args)

            expect do
              deleter.delete_instance_plans([instance_plan], event_log_stage)
            end.to change { Models::Instance.all.select { |i| i.active_vm == existing_vm }.count }.from(1).to(0)
          end
        end
      end
    end
  end
end
